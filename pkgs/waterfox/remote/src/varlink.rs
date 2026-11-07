//! The Varlink transport: NUL-terminated JSON calls on the user's unix
//! socket, one for every profile, `org.varlink.service` included, so `varlinkctl info | introspect
//! | call` work on it unmodified.
use crate::core::{Error, Profiles};
use anyhow::{bail, Context, Result};
use serde_json::{json, Value};
use std::path::Path;
use std::sync::Arc;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::unix::OwnedWriteHalf;
use tokio::net::{UnixListener, UnixStream};

pub const INTERFACE: &str = "ad.lar.WaterfoxRemote";
pub const DESCRIPTION: &str = include_str!("ad.lar.WaterfoxRemote.varlink");

const SERVICE_DESCRIPTION: &str = "\
# The Varlink Service Interface is provided by every varlink service. It
# describes the service and the interfaces it implements.
interface org.varlink.service

# Get a list of all the interfaces a service provides and information
# about the implementation.
method GetInfo() -> (
  vendor: string,
  product: string,
  version: string,
  url: string,
  interfaces: []string
)

# Get the description of an interface that is implemented by this service.
method GetInterfaceDescription(interface: string) -> (description: string)

# The requested interface was not found.
error InterfaceNotFound (interface: string)

# The requested method was not found
error MethodNotFound (method: string)

# The interface defines the requested method, but the service does not
# implement it.
error MethodNotImplemented (method: string)

# One of the passed parameters is invalid.
error InvalidParameter (parameter: string)

# Client is denied access
error PermissionDenied ()

# Method is expected to be called with 'more' set to true, but wasn't
error ExpectedMore ()
";

pub async fn serve(listener: UnixListener, core: Arc<Profiles>) {
    while let Ok((stream, _)) = listener.accept().await {
        let core = core.clone();
        tokio::spawn(async move {
            let _ = connection(stream, core).await;
        });
    }
}

async fn send(write: &mut OwnedWriteHalf, reply: &Value) -> Result<()> {
    let mut bytes = serde_json::to_vec(reply)?;
    bytes.push(0);
    write.write_all(&bytes).await?;
    Ok(())
}

fn error(name: &str, parameters: Value) -> Value {
    json!({"error": name, "parameters": parameters})
}

fn core_error(error: &Error) -> Value {
    match error {
        Error::UnknownProfile(profile) => self::error(
            &format!("{INTERFACE}.ProfileNotFound"),
            json!({"profile": profile}),
        ),
        Error::NotConnected => self::error(&format!("{INTERFACE}.BrowserNotConnected"), json!({})),
        Error::Browser(message) => self::error(
            &format!("{INTERFACE}.BrowserError"),
            json!({"message": message}),
        ),
    }
}

fn string_parameter<'a>(parameters: &'a Value, name: &str) -> Result<&'a str, Value> {
    parameters[name].as_str().ok_or_else(|| {
        error(
            "org.varlink.service.InvalidParameter",
            json!({"parameter": name}),
        )
    })
}

/// Calls are answered in order, as Varlink requires; a connection may carry
/// any number of them.
async fn connection(stream: UnixStream, core: Arc<Profiles>) -> Result<()> {
    let (read, mut write) = stream.into_split();
    let mut read = BufReader::new(read);
    loop {
        let mut message = Vec::new();
        if read.read_until(0, &mut message).await? == 0 {
            return Ok(());
        }
        if message.pop() != Some(0) {
            bail!("connection closed mid-message");
        }
        let call: Value = serde_json::from_slice(&message).context("not a Varlink call")?;
        let method = call["method"].as_str().unwrap_or_default();
        let parameters = call.get("parameters").cloned().unwrap_or_else(|| json!({}));
        let oneway = call["oneway"].as_bool().unwrap_or(false);
        let more = call["more"].as_bool().unwrap_or(false);

        if method == format!("{INTERFACE}.WatchLauncher") {
            if !more {
                send(
                    &mut write,
                    &error("org.varlink.service.ExpectedMore", json!({})),
                )
                .await?;
                continue;
            }
            // Streams until the client goes away; nothing else is read from
            // this connection meanwhile.
            let mut queries = core.launcher.subscribe();
            loop {
                match queries.recv().await {
                    Ok(query) => {
                        let reply = json!({"parameters": query, "continues": true});
                        send(&mut write, &reply).await?;
                    }
                    Err(tokio::sync::broadcast::error::RecvError::Lagged(_)) => {}
                    Err(tokio::sync::broadcast::error::RecvError::Closed) => return Ok(()),
                }
            }
        }

        let reply = dispatch(&core, method, &parameters).await;
        if !oneway {
            send(&mut write, &reply).await?;
        }
    }
}

async fn dispatch(profiles: &Profiles, method: &str, parameters: &Value) -> Value {
    let profile = parameters["profile"].as_str().unwrap_or("default");
    let core = match (
        method.rsplit_once('.').map(|(i, _)| i),
        profiles.get(profile),
    ) {
        (Some(INTERFACE), Err(e))
            if !method.ends_with(".Profiles") && !method.ends_with(".Open") =>
        {
            return core_error(&e)
        }
        (_, core) => core.ok(),
    };
    let (interface, member) = method.rsplit_once('.').unwrap_or(("", method));
    match (interface, member) {
        ("org.varlink.service", "GetInfo") => json!({"parameters": {
            "vendor": "lar.ad",
            "product": "waterfox-remote",
            "version": env!("CARGO_PKG_VERSION"),
            "url": "https://tangled.org/larandar.tngl.sh/nur-packages",
            "interfaces": ["org.varlink.service", INTERFACE],
        }}),
        ("org.varlink.service", "GetInterfaceDescription") => {
            match parameters["interface"].as_str() {
                Some("org.varlink.service") => {
                    json!({"parameters": {"description": SERVICE_DESCRIPTION}})
                }
                Some(INTERFACE) => json!({"parameters": {"description": DESCRIPTION}}),
                Some(other) => error(
                    "org.varlink.service.InterfaceNotFound",
                    json!({"interface": other}),
                ),
                None => error(
                    "org.varlink.service.InvalidParameter",
                    json!({"parameter": "interface"}),
                ),
            }
        }
        (INTERFACE, "Profiles") => {
            let mut list = Vec::new();
            for core in profiles.all() {
                list.push(json!({"name": core.name, "connected": core.connected().await}));
            }
            json!({"parameters": {"profiles": list}})
        }
        (INTERFACE, "Tabs") => match core.expect("checked above").tabs().await {
            Ok(tabs) => json!({"parameters": {"tabs": tabs}}),
            Err(e) => core_error(&e),
        },
        (INTERFACE, "Focus") => match string_parameter(parameters, "context") {
            Ok(context) => match core.expect("checked above").focus(context).await {
                Ok(()) => json!({"parameters": {}}),
                Err(e) => core_error(&e),
            },
            Err(reply) => reply,
        },
        (INTERFACE, "Open") => match string_parameter(parameters, "url") {
            Ok(url) => {
                let headless = parameters["headless"].as_bool().unwrap_or(false);
                match profiles.open(profile, url, headless).await {
                    Ok(context) => json!({"parameters": {"context": context}}),
                    Err(e) => core_error(&e),
                }
            }
            Err(reply) => reply,
        },
        ("org.varlink.service" | INTERFACE, _) => error(
            "org.varlink.service.MethodNotFound",
            json!({"method": method}),
        ),
        _ => error(
            "org.varlink.service.InterfaceNotFound",
            json!({"interface": interface}),
        ),
    }
}

/// One call, one reply (or, with `more`, a reply per line until the
/// service stops): the client half of the CLI.
pub async fn call(
    socket: &Path,
    method: &str,
    parameters: Value,
    more: bool,
    mut each: impl FnMut(&Value),
) -> Result<()> {
    let stream = UnixStream::connect(socket).await.with_context(|| {
        format!(
            "waterfox-remote daemon not reachable at {}",
            socket.display()
        )
    })?;
    let (read, mut write) = stream.into_split();
    let mut request = json!({"method": method, "parameters": parameters});
    if more {
        request["more"] = json!(true);
    }
    send(&mut write, &request).await?;
    let mut read = BufReader::new(read);
    loop {
        let mut message = Vec::new();
        if read.read_until(0, &mut message).await? == 0 {
            bail!("daemon closed the connection");
        }
        message.pop();
        let reply: Value = serde_json::from_slice(&message)?;
        if let Some(name) = reply["error"].as_str() {
            match reply["parameters"]["message"].as_str() {
                Some(message) => bail!("{name}: {message}"),
                None if name.ends_with(".BrowserNotConnected") => {
                    bail!("{}", Error::NotConnected)
                }
                None => bail!("{name}"),
            }
        }
        each(&reply["parameters"]);
        if !reply["continues"].as_bool().unwrap_or(false) {
            return Ok(());
        }
    }
}
