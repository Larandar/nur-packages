# Pull requests on Tangled: ATProto records (`sh.tangled.repo.pull`) in the publishing account's repository, each
# round a gzipped git-format-patch, and their state as `sh.tangled.repo.pull.status` records.

const pull_collection = "sh.tangled.repo.pull"
const status_collection = "sh.tangled.repo.pull.status"

def now []: nothing -> string {
    date now | date to-timezone UTC | format date "%Y-%m-%dT%H:%M:%S%.3fZ"
}

# A session for the account `$env.NUR_HANDLE`, authenticated with the app password `$env.NUR_APP_PASSWORD`.
export def session []: nothing -> record {
    let did = http get $"https://($env.NUR_HANDLE)/.well-known/atproto-did" | str trim
    let pds = http get $"https://plc.directory/($did)" | get service | where id == "#atproto_pds" | get 0.serviceEndpoint
    let auth = http post --content-type application/json $"($pds)/xrpc/com.atproto.server.createSession" {
        identifier: $did
        password: $env.NUR_APP_PASSWORD
    }
    {pds: $pds, did: $did, jwt: $auth.accessJwt}
}

def authorization [session: record]: nothing -> list<string> {
    [Authorization $"Bearer ($session.jwt)"]
}

# Every record of `collection` in the session's repository.
def records [session: record, collection: string]: nothing -> list<record> {
    mut cursor = null
    mut found = []
    loop {
        let query = {repo: $session.did, collection: $collection, limit: 100} | merge (if $cursor == null { {} } else { {cursor: $cursor} })
        let page = http get --headers (authorization $session) $"($session.pds)/xrpc/com.atproto.repo.listRecords?($query | url build-query)"
        $found = $found ++ $page.records
        if ($page.cursor? == null) or ($page.records | is-empty) { break }
        $cursor = $page.cursor
    }
    $found
}

def create-record [session: record, collection: string, record: record]: nothing -> string {
    let created = http post --content-type application/json --headers (authorization $session) $"($session.pds)/xrpc/com.atproto.repo.createRecord" {
        repo: $session.did
        collection: $collection
        record: ($record | insert '$type' $collection)
    }
    $created.uri
}

def put-record [session: record, uri: string, record: record]: nothing -> nothing {
    let collection = $uri | split row '/' | get 3
    http post --content-type application/json --headers (authorization $session) $"($session.pds)/xrpc/com.atproto.repo.putRecord" {
        repo: $session.did
        collection: $collection
        rkey: ($uri | split row '/' | last)
        record: ($record | upsert '$type' $collection)
    } | ignore
}

# The changes `branch` makes since it forked from `base`, as one gzipped format-patch blob.
def patch-blob [session: record, branch: string, base: string, title: string]: nothing -> record {
    let fork = ^git merge-base $base $branch | str trim
    let commit = ^git commit-tree $"($branch)^{tree}" -p $fork -m $title | str trim
    let bytes = ^git format-patch -1 --stdout $commit | ^gzip -n -c | into binary
    let uploaded = http post --content-type application/gzip --headers (authorization $session) $"($session.pds)/xrpc/com.atproto.repo.uploadBlob" $bytes
    $uploaded.blob
}

# Open pull requests from `branch`: those whose latest status is neither merged nor closed.
def open-pulls [session: record, repo: string, branch: string]: nothing -> list<record> {
    let statuses = records $session $status_collection | each { get value } | sort-by createdAt
    records $session $pull_collection
    | where {|pull| $pull.value.target.repo == $repo and $pull.value.source?.branch? == $branch }
    | where {|pull|
        let latest = $statuses | where pull == $pull.uri | last
        ($latest | is-empty) or ($latest.status | str ends-with ".open")
    }
}

# Open a pull request from `branch` into `target` of `repo`, or add a round to the open one when the branch changed.
# Returns the pull request's AT URI.
export def open-or-update [
    session: record
    repo: string # The repository's DID
    branch: string
    target: string
    title: string
    body: string
]: nothing -> string {
    let blob = patch-blob $session $branch $target $title
    let round = {createdAt: (now), patchBlob: $blob}
    let existing = open-pulls $session $repo $branch
    if ($existing | is-empty) {
        create-record $session $pull_collection {
            title: $title
            body: $body
            source: {branch: $branch}
            target: {repo: $repo, branch: $target}
            rounds: [$round]
            createdAt: (now)
        }
    } else {
        let pull = $existing | last
        let last_round = $pull.value.rounds | last
        if $last_round.patchBlob.ref != $blob.ref {
            let rounds = $pull.value.rounds | append $round
            put-record $session $pull.uri ($pull.value | upsert rounds $rounds | upsert title $title | upsert body $body)
        }
        $pull.uri
    }
}

# Record the open pull requests from `branch` as merged (or closed).
export def settle [session: record, repo: string, branch: string, --closed]: nothing -> nothing {
    let state = if $closed { "closed" } else { "merged" }
    for pull in (open-pulls $session $repo $branch) {
        create-record $session $status_collection {
            pull: $pull.uri
            status: $"sh.tangled.repo.pull.status.($state)"
            createdAt: (now)
        } | ignore
    }
}
