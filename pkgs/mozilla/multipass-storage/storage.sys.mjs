/* Waterfox's login storage over multipass (ad.lar.MultiPass): the browser's
 * own login UI (autocomplete, the save and update prompts, about:logins)
 * reads and writes the user's password managers instead of logins.json.
 * AutoConfig installs it in place of LoginManagerStorage.create.
 *
 * Nothing of a vault is kept here: every read asks the service, and a
 * locked vault yields no logins. A write the user starts (save, update,
 * delete) unlocks the vault it needs, through the manager's own prompt, and
 * is tried once more. Sync, breach-alert and vulnerable-password bookkeeping
 * live in memory for the session, as the vault has no place for them.
 */
const { LoginHelper } = ChromeUtils.importESModule("resource://gre/modules/LoginHelper.sys.mjs");

const INTERFACE = "ad.lar.MultiPass";

function socketPath() {
  const runtime = Services.env.get("XDG_RUNTIME_DIR");
  if (!runtime) {
    throw new Error("XDG_RUNTIME_DIR is not set: no multipass socket to reach");
  }
  return PathUtils.join(runtime, "multipass", "varlink.sock");
}

class VarlinkError extends Error {
  constructor(error, parameters) {
    super(`${error} ${JSON.stringify(parameters)}`);
    this.error = error;
    this.parameters = parameters;
  }
}

/* One call per connection: a JSON message out and one back, each ended by a
 * NUL byte, over the platform's unix-domain socket transport. */
function call(method, parameters = {}) {
  return new Promise((resolve, reject) => {
    let transport;
    try {
      const file = Cc["@mozilla.org/file/local;1"].createInstance(Ci.nsIFile);
      file.initWithPath(socketPath());
      transport = Cc["@mozilla.org/network/socket-transport-service;1"]
        .getService(Ci.nsISocketTransportService)
        .createUnixDomainTransport(file);
      const output = Cc["@mozilla.org/binaryoutputstream;1"].createInstance(Ci.nsIBinaryOutputStream);
      output.setOutputStream(transport.openOutputStream(Ci.nsITransport.OPEN_BLOCKING, 0, 0));
      output.writeByteArray(new TextEncoder().encode(`${JSON.stringify({ method: `${INTERFACE}.${method}`, parameters })}\0`));
      const raw = transport.openInputStream(0, 0, 0).QueryInterface(Ci.nsIAsyncInputStream);
      const input = Cc["@mozilla.org/binaryinputstream;1"].createInstance(Ci.nsIBinaryInputStream);
      input.setInputStream(raw);
      const bytes = [];
      const finish = () => {
        transport.close(Cr.NS_OK);
        const end = bytes.indexOf(0);
        if (end < 0) {
          reject(new Error(`multipass closed the connection during ${method}`));
          return;
        }
        const reply = JSON.parse(new TextDecoder().decode(new Uint8Array(bytes.slice(0, end))));
        if (reply.error) reject(new VarlinkError(reply.error, reply.parameters ?? {}));
        else resolve(reply.parameters ?? {});
      };
      const wait = () =>
        raw.asyncWait(
          {
            onInputStreamReady() {
              try {
                const available = raw.available();
                if (available > 0) bytes.push(...input.readByteArray(available));
              } catch (e) {
                // The service closed its end: what arrived is the reply.
                finish();
                return;
              }
              if (bytes.includes(0)) finish();
              else wait();
            },
          },
          0,
          0,
          Services.tm.currentThread,
        );
      wait();
    } catch (e) {
      transport?.close(Cr.NS_OK);
      reject(e);
    }
  });
}

/* A call that may meet a locked vault: unlock that one, try once more. */
async function unlocking(method, parameters) {
  try {
    return await call(method, parameters);
  } catch (e) {
    if (e.error !== `${INTERFACE}.Locked`) throw e;
    await call("Unlock", { manager: e.parameters.manager });
    return call(method, parameters);
  }
}

function toLoginInfo(login) {
  const info = Cc["@mozilla.org/login-manager/loginInfo;1"].createInstance(Ci.nsILoginInfo);
  info.init(
    login.origin ?? "",
    login.httpRealm ? null : (login.formActionOrigin ?? login.origin ?? ""),
    login.httpRealm ?? null,
    login.username ?? "",
    login.password ?? "",
    login.usernameField ?? "",
    login.passwordField ?? "",
  );
  info.QueryInterface(Ci.nsILoginMetaInfo);
  info.guid = login.id;
  info.timeCreated = 0;
  info.timeLastUsed = 0;
  info.timePasswordChanged = 0;
  info.timesUsed = 0;
  return info;
}

function toInput(info) {
  return {
    origin: info.origin || null,
    formActionOrigin: info.formActionOrigin || null,
    httpRealm: info.httpRealm || null,
    username: info.username ?? "",
    usernameField: info.usernameField || null,
    passwordField: info.passwordField || null,
    password: info.password ?? "",
  };
}

/* Firefox's own matching, over the candidates multipass found by site. */
function matching(login, matchData, options) {
  if ("guid" in matchData) return login.guid === matchData.guid;
  if (matchData.origin !== undefined && !LoginHelper.isOriginMatching(login.origin, matchData.origin, options)) {
    return false;
  }
  if (
    matchData.formActionOrigin !== undefined &&
    matchData.formActionOrigin !== "" &&
    login.formActionOrigin !== "" &&
    !LoginHelper.isOriginMatching(login.formActionOrigin, matchData.formActionOrigin, options)
  ) {
    return false;
  }
  if (matchData.httpRealm !== undefined && login.httpRealm !== matchData.httpRealm) return false;
  for (const field of ["username", "usernameField", "passwordField"]) {
    if (matchData[field] !== undefined && login[field] !== matchData[field]) return false;
  }
  return true;
}

export class MultipassStorage {
  #vulnerable = new Set();
  #breachDismissals = {};
  #syncID = null;
  #lastSync = 0;

  QueryInterface = ChromeUtils.generateQI([]);

  set isActive(_) {}
  get uiBusy() {
    return false;
  }
  get isLoggedIn() {
    return true;
  }

  initialize() {
    return Promise.resolve();
  }
  terminate() {
    return Promise.resolve();
  }

  async #search(origin, passwords) {
    try {
      const found = await call("Search", { origin: origin || null, passwords });
      return found.logins.map(toLoginInfo);
    } catch (e) {
      console.warn("multipass:", e.message);
      return [];
    }
  }

  async getAllLogins() {
    return this.#search(null, true);
  }

  async searchLoginsAsync(matchData) {
    const options = {
      schemeUpgrades: !!matchData.schemeUpgrades,
      acceptDifferentSubdomains: !!matchData.acceptDifferentSubdomains,
      acceptRelatedRealms: !!matchData.acceptRelatedRealms,
      relatedRealms: matchData.relatedRealms ?? [],
    };
    if ("guid" in matchData) {
      try {
        return [toLoginInfo((await call("Get", { id: matchData.guid })).login)];
      } catch {
        return [];
      }
    }
    const site = matchData.origin ?? matchData.formActionOrigin ?? null;
    return (await this.#search(site, true)).filter(login => matching(login, matchData, options));
  }

  async countLoginsAsync(origin, formActionOrigin, httpRealm) {
    const matchData = {};
    if (origin) matchData.origin = origin;
    if (formActionOrigin) matchData.formActionOrigin = formActionOrigin;
    if (httpRealm) matchData.httpRealm = httpRealm;
    return (await this.searchLoginsAsync(matchData)).length;
  }

  async addLoginsAsync(logins, continueOnDuplicates = false) {
    const added = [];
    for (const login of logins) {
      const existing = await this.searchLoginsAsync({
        origin: login.origin,
        formActionOrigin: login.formActionOrigin ?? undefined,
        httpRealm: login.httpRealm ?? undefined,
      });
      const duplicate = existing.find(l => login.matches(l, true));
      if (duplicate) {
        if (continueOnDuplicates) continue;
        throw LoginHelper.createLoginAlreadyExistsError(duplicate.guid);
      }
      const { id } = await unlocking("Add", { manager: null, login: toInput(login) });
      const stored = toLoginInfo({ ...toInput(login), id });
      LoginHelper.notifyStorageChanged("addLogin", stored);
      added.push(stored);
    }
    return added;
  }

  async modifyLoginAsync(oldLogin, newLoginData) {
    const [old] = await this.searchLoginsAsync({ guid: oldLogin.QueryInterface(Ci.nsILoginMetaInfo).guid });
    if (!old) throw new Error("No matching logins");
    const updated = LoginHelper.buildModifiedLogin(old, newLoginData);
    const { id } = await unlocking("Modify", { id: old.guid, login: toInput(updated) });
    updated.QueryInterface(Ci.nsILoginMetaInfo).guid = id;
    LoginHelper.notifyStorageChanged("modifyLogin", [old, updated]);
  }

  async removeLoginAsync(login) {
    const id = login.QueryInterface(Ci.nsILoginMetaInfo).guid;
    await unlocking("Remove", { id });
    LoginHelper.notifyStorageChanged("removeLogin", login);
  }

  async recordPasswordUseAsync() {}

  // "Remove all" in about:logins would empty the user's vaults.
  async removeAllLoginsAsync() {
    throw new Error("multipass: removing every login of the user's vaults is refused");
  }
  async removeAllUserFacingLoginsAsync() {
    throw new Error("multipass: removing every login of the user's vaults is refused");
  }

  async loginIsDeletedAsync() {
    return false;
  }
  async reencryptAllLogins() {}

  async getSyncID() {
    return this.#syncID;
  }
  async setSyncID(syncID) {
    this.#syncID = syncID;
  }
  async getLastSync() {
    return this.#lastSync;
  }
  async setLastSync(timestamp) {
    this.#lastSync = timestamp;
  }
  async resetSyncCounter() {}

  async recordBreachAlertDismissal(guid) {
    this.#breachDismissals[guid] = { timeBreachAlertDismissed: Date.now() };
  }
  async getBreachAlertDismissalsByLoginGUID() {
    return this.#breachDismissals;
  }

  async addPotentiallyVulnerablePassword(login) {
    this.#vulnerable.add(login.password);
  }
  async isPotentiallyVulnerablePassword(login) {
    return this.#vulnerable.has(login.password);
  }
  async arePotentiallyVulnerablePasswords(logins) {
    return logins.map(login => this.#vulnerable.has(login.password));
  }
  async clearAllPotentiallyVulnerablePasswords() {
    this.#vulnerable.clear();
  }
}
