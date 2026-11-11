import Foundation

func usage() -> String {
    """
    canoe — local-first API client CLI (Canoe vault reader/sender)

    USAGE:
      canoe [--vault <path>] [--json] <command> [args]

    COMMANDS:
      init [target-dir]           Write CANOE_AGENT.md skill file into target-dir (default: cwd)
      vault info                  Show vault counts and paths
      workspace list              List workspaces
      collection list             List collections
      collection get <id|name>    Dump one collection as JSON
      collection export <id|name> Dump one collection to file/stdout (same as get, --output path)
      collection run <id|name>    Send every request in a collection sequentially
      request list                List requests (requires --collection <id|name>)
      request get <id|name>       Dump one request (requires --collection)
      request preview <id|name>   Preview resolved URL/headers/body without sending (--collection)
      request send <id|name>      Send one request (requires --collection)
      env list                    List environments
      env get <id|name>           Dump one environment as JSON

    FLAGS:
      --vault <path>     Vault root (or vault/ dir). Default: $CANOE_VAULT /
                         ~/Library/Application Support/Canoe, else iCloud Canoe
      --json             Machine JSON output (for agents). Default for get/run/send.
      --env <id|name>    Environment for variable resolution
      --collection <id|name>  Collection for request commands
      --var key=value    Extra variable override (repeatable)
      --timeout <sec>    Send timeout (default 30)
      --no-cookies       Disable cookie jar
      --dry-run          Send only builds URLRequest (no network) — alias for request preview
      --output <path>    For collection export: write JSON to file instead of stdout

    Lookup accepts UUID or name (exact, then substring).
    Variables resolve {{name}} in order: workspace → collection → environment,
    then --var overrides. Unknown placeholders stay as-is.

    EXAMPLES:
      canoe workspace list --json
      canoe collection list --json
      canoe request list --collection CS --json
      canoe request get "/v1/console/me" --collection CS --env "3 Staging" --json
      canoe request preview "/v1/console/me" --collection CS --env "3 Staging" --json
      canoe request send "/v1/console/me" --collection CS --var cs_base_url=https://example.invalid --json
      canoe collection run CS --env staging --json
      canoe vault info
      canoe init /tmp/myproj
      CANOE_VAULT=~/.../Canoe canoe env list --json
    """
}
