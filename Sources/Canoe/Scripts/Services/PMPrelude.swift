import Foundation

/// The JavaScript environment evaluated before every script phase: the
/// postman-style `pm` surface (`pm.environment` / `pm.variables` /
/// `pm.request` / `pm.response`, chai-style `pm.expect`, `pm.test`), a
/// console sink, and the phase reset/teardown functions the Swift side
/// calls. Plain ES2023 - the QuickJS runtime exposes no std/os modules, so
/// everything here works inside the sandbox.
///
/// Host bridge functions it calls (registered from Swift, see
/// `ScriptEngine`):
/// - `__pm_vars_get(name)` -> string | null
/// - `__pm_vars_set(name, value)` -> undefined
/// - `__pm_vars_unset(name)` -> undefined
/// - `__pm_vars_json()` -> JSON string (merged variable view)
/// - `__pm_scope_get(kind, name)` -> string | undefined
/// - `__pm_scope_set(kind, name, value)` -> undefined
/// - `__pm_scope_unset(kind, name)` -> undefined
/// - `__pm_scope_json(kind)` -> JSON string | undefined
/// - `__pm_request_header_add(name, value)` -> undefined
/// - `__pm_request_header_upsert(name, value)` -> undefined
/// - `__pm_request_header_remove(name)` -> undefined
/// - `__pm_request_snapshot()` -> JSON string | null
/// - `__pm_response_snapshot()` -> JSON string | null
///
/// The prelude is re-evaluated before each phase, so a script that clobbers
/// globals cannot poison the next phase.
enum PMPrelude {
    static let source = """
        "use strict";

        var __pm_state = { results: [], logs: [], kind: null, sendCounter: 0 };
        var __pm_logLimit = 200;
        var __pm_textLimit = 4000;

        // Console lines and assertion messages land in the response
        // snapshot (machine-local response history), so a script dumping a
        // huge object gets truncated here rather than bloating the store.
        function __pm_cap(text) {
          var suffix = "...[truncated]";
          return text.length > __pm_textLimit
            ? text.slice(0, __pm_textLimit - suffix.length) + suffix
            : text;
        }

        function __pm_show(value) {
          try {
            var asJSON = JSON.stringify(value);
            return asJSON === undefined ? String(value) : asJSON;
          } catch (error) {
            return String(value);
          }
        }

        function __pm_push_log(level, parts) {
          if (__pm_state.logs.length >= __pm_logLimit) { return; }
          var text = "";
          for (var i = 0; i < parts.length; i++) {
            if (i > 0) { text += " "; }
            var part = parts[i];
            text += typeof part === "string" ? part : __pm_show(part);
          }
          __pm_state.logs.push({ level: level, message: __pm_cap(text) });
        }

        // Strings pass through raw (console text, variable values);
        // everything else goes through the JSON view with a String()
        // fallback.
        function __pm_stringify(value) {
          if (typeof value === "string") { return value; }
          if (typeof value === "number" || typeof value === "boolean") {
            return String(value);
          }
          if (value === null || value === undefined) { return ""; }
          return __pm_show(value);
        }

        // Postman's header-object shape: { key, value }. A blank key is a
        // script bug worth surfacing, not a silent no-op.
        function __pm_header_pair(header, op) {
          if (
            header === null || typeof header !== "object"
            || (typeof header.key !== "string" && typeof header.key !== "number")
          ) {
            throw new TypeError("pm.request.headers." + op + " expects { key, value }");
          }
          var key = String(header.key).trim();
          if (!key) {
            throw new TypeError("pm.request.headers." + op + ": header key must not be empty");
          }
          var value =
            header.value === undefined || header.value === null
              ? ""
              : __pm_stringify(header.value);
          return { key: key, value: value };
        }

        function __pm_reset_phase(kind) {
          __pm_state.results = [];
          __pm_state.logs = [];
          __pm_state.kind = kind;
          buildPm();
        }

        function __pm_results_json() {
          return JSON.stringify({ results: __pm_state.results, logs: __pm_state.logs });
        }

        // A function declaration, not a `class`: the prelude is re-evaluated
        // before every phase on a persistent runtime, and a top-level class
        // binding is lexical - the second evaluation would throw
        // "redeclaration of 'PMAssertionError'" and kill every later send of
        // the session. Function declarations land on the global object and
        // redeclare cleanly.
        function PMAssertionError(message) {
          var error = new Error(message);
          error.name = "AssertionError";
          return error;
        }

        function pmVariables() {
          return {
            get: function (name) {
              var value = __pm_vars_get(String(name));
              return value === null ? undefined : value;
            },
            has: function (name) {
              return __pm_vars_get(String(name)) !== null;
            },
            set: function (name, value) {
              __pm_vars_set(String(name), __pm_stringify(value));
            },
            unset: function (name) {
              __pm_vars_unset(String(name));
            },
            toObject: function () {
              try { return JSON.parse(__pm_vars_json()); } catch (error) { return {}; }
            },
            replaceIn: function (text) {
              return __pm_resolve(String(text ?? ""));
            },
          };
        }

        // Postman's read-side scope objects (VariableScope): get/has read
        // ONE scope (its script writes first, then the stored map minus its
        // unsets); set/unset write that scope for this send. The send
        // pipeline persists the final writes to the machine-local overrides
        // layer (see VariableOverrides) so later sends of other requests
        // resolve them; the vault files themselves are never written by
        // scripts.
        function pmScope(kind) {
          return {
            get: function (name) {
              var value = __pm_scope_get(kind, String(name));
              return value === undefined ? undefined : value;
            },
            has: function (name) {
              return __pm_scope_get(kind, String(name)) !== undefined;
            },
            toObject: function () {
              try { return JSON.parse(__pm_scope_json(kind)); } catch (error) { return {}; }
            },
            set: function (name, value) {
              __pm_scope_set(kind, String(name), __pm_stringify(value));
            },
            unset: function (name) {
              __pm_scope_unset(kind, String(name));
            },
          };
        }

        function pmRequest(req) {
          var headers = (req && req.headers) || {};
          var raw = (req && req.url) || "";
          // Fragment first (it may wrap a query), then query, then the
          // authority/path split - all over the raw (unresolved) text.
          var hash = "";
          var hashIndex = raw.indexOf("#");
          if (hashIndex >= 0) {
            hash = raw.slice(hashIndex + 1);
            raw = raw.slice(0, hashIndex);
          }
          var queryIndex = raw.indexOf("?");
          var beforeQuery = queryIndex >= 0 ? raw.slice(0, queryIndex) : raw;
          var queryString = queryIndex >= 0 ? raw.slice(queryIndex + 1) : "";
          var protocol = "";
          var host = "";
          var port = "";
          var path = "";
          var protocolSplit = beforeQuery.split("://");
          if (protocolSplit.length > 1) {
            protocol = protocolSplit[0];
            var authorityAndPath = protocolSplit.slice(1).join("://");
            var slashIndex = authorityAndPath.indexOf("/");
            var authority =
              slashIndex >= 0 ? authorityAndPath.slice(0, slashIndex) : authorityAndPath;
            path = slashIndex >= 0 ? authorityAndPath.slice(slashIndex) : "";
            // Port splits off the authority's last colon when what follows
            // is digits (a bare IPv6 literal has colons but no numeric tail).
            var colonIndex = authority.lastIndexOf(":");
            if (colonIndex >= 0 && /^\\d+$/.test(authority.slice(colonIndex + 1))) {
              port = authority.slice(colonIndex + 1);
              host = authority.slice(0, colonIndex);
            } else {
              host = authority;
            }
          } else {
            path = beforeQuery;
          }
          var hostSegments = host === "" ? [] : host.split(".");
          var query = [];
          if (queryString.length > 0) {
            query = queryString
              .split("&")
              .filter(function (pair) { return pair.length > 0; })
              .map(function (pair) {
                var eq = pair.indexOf("=");
                return {
                  key: eq >= 0 ? pair.slice(0, eq) : pair,
                  value: eq >= 0 ? pair.slice(eq + 1) : "",
                };
              });
          }
          return {
            method: (req && req.method) || "GET",
            // Postman's Url object: host as the segment array (postman-
            // collection SDK shape), toString in string context, and the
            // get* helpers scripts commonly reach for.
            url: {
              toString: function () { return raw; },
              protocol: protocol,
              host: hostSegments,
              port: port,
              path: path,
              query: query,
              hash: hash,
              getHost: function () { return hostSegments.join("."); },
              getPath: function (withQuery) {
                return withQuery && queryString.length > 0
                  ? path + "?" + queryString
                  : path;
              },
              getQueryString: function () { return queryString; },
            },
            headers: {
              get: function (name) {
                var value = headers[String(name).toLowerCase()];
                return value === undefined ? undefined : value;
              },
              has: function (name) {
                return Object.prototype.hasOwnProperty.call(headers, String(name).toLowerCase());
              },
              all: function () {
                return Object.keys(headers).map(function (key) {
                  return { key: key, value: headers[key] };
                });
              },
              // Postman's programmatic header mutation: the pair lands on
              // the OUTGOING request (add appends, upsert replaces the
              // enabled same-name rows, remove drops them), not on the tab.
              // In the post-response phase the call is recorded but
              // discarded.
              add: function (header) {
                var pair = __pm_header_pair(header, "add");
                __pm_request_header_add(pair.key, pair.value);
              },
              upsert: function (header) {
                var pair = __pm_header_pair(header, "upsert");
                __pm_request_header_upsert(pair.key, pair.value);
              },
              remove: function (name) {
                __pm_request_header_remove(String(name).trim());
              },
            },
            body: {
              raw: typeof req.body === "string" ? req.body : null,
            },
          };
        }

        function pmResponse(resp) {
          var headers = (resp && resp.headers) || {};
          return {
            code: resp.code,
            status: typeof resp.status === "string" ? resp.status : "",
            responseTime: typeof resp.responseTimeMs === "number" ? resp.responseTimeMs : 0,
            responseSize: typeof resp.responseSize === "number" ? resp.responseSize : 0,
            body: typeof resp.body === "string" ? resp.body : "",
            headers: {
              get: function (name) {
                var value = headers[String(name).toLowerCase()];
                return value === undefined ? undefined : value;
              },
              has: function (name) {
                return Object.prototype.hasOwnProperty.call(headers, String(name).toLowerCase());
              },
              all: function () {
                return Object.keys(headers).map(function (key) {
                  return { key: key, value: headers[key] };
                });
              },
            },
            text: function () {
              return typeof resp.body === "string" ? resp.body : "";
            },
            json: function () {
              return JSON.parse(resp.body);
            },
            to: {
              have: {
                status: function (expected) {
                  if (resp.code !== expected) {
                    throw new PMAssertionError(
                      "expected response status " + expected + " but got " + resp.code);
                  }
                },
              },
            },
          };
        }

        function buildPm() {
          var vars = pmVariables();
          var requestJSON = __pm_request_snapshot();
          var responseJSON = __pm_response_snapshot();
          var req = requestJSON === null ? null : JSON.parse(requestJSON);
          var resp = responseJSON === null ? null : JSON.parse(responseJSON);
          globalThis.pm = {
            info: {
              eventName: __pm_state.kind === "prerequest" ? "prerequest" : "test",
              requestName: req && typeof req.name === "string" ? req.name : "",
              requestId: req && typeof req.id === "string" ? req.id : "",
            },
            variables: vars,
            environment: pmScope("environment"),
            globals: pmScope("workspace"),
            collectionVariables: pmScope("collection"),
            cookies: (function () {
              var jar = [];
              try { jar = JSON.parse(__pm_cookies_json()); } catch (error) { jar = []; }
              return {
                get: function (name) {
                  var hit = jar.find(function (c) { return c.name === String(name); });
                  return hit ? hit.value : undefined;
                },
                has: function (name) {
                  return jar.some(function (c) { return c.name === String(name); });
                },
                all: function () {
                  return jar.map(function (c) { return { name: c.name, value: c.value }; });
                },
              };
            })(),
            request: req === null ? null : pmRequest(req),
            response: resp === null ? null : pmResponse(resp),
            expect: expect,
            test: pmTest,
            // Postman's async sub-request: registers the callback, queues
            // the spec through the engine, and returns immediately - the
            // callback runs (err, response) once the sub-request lands,
            // before the send/handshake completes.
            sendRequest: function (specOrURL, callback) {
              if (typeof callback !== "function") {
                throw new Error("pm.sendRequest expects (urlOrSpec, callback)");
              }
              var spec;
              if (typeof specOrURL === "string") {
                spec = { url: specOrURL, method: "GET", header: [], body: null };
              } else if (specOrURL && typeof specOrURL === "object") {
                spec = specOrURL;
              } else {
                throw new Error("pm.sendRequest expects a URL string or a request spec object");
              }
              var url = typeof spec.url === "string"
                ? spec.url
                : (spec.url && typeof spec.url.toString === "function" ? spec.url.toString() : "");
              var header = Array.isArray(spec.header) ? spec.header : [];
              var body = null;
              if (spec.body && typeof spec.body === "object") {
                if (typeof spec.body.raw === "string") {
                  body = spec.body.raw;
                } else if (Array.isArray(spec.body.urlencoded)) {
                  body = spec.body.urlencoded
                    .filter(function (row) { return row && typeof row.key === "string"; })
                    .map(function (row) {
                      var value = typeof row.value === "string" ? row.value : "";
                      return encodeURIComponent(row.key) + "=" + encodeURIComponent(value);
                    })
                    .join("&");
                }
              } else if (typeof spec.body === "string") {
                body = spec.body;
              }
              var method = typeof spec.method === "string" && spec.method ? spec.method.toUpperCase() : "GET";
              var id = ++__pm_state.sendCounter;
              globalThis["__pm_send_cb_" + id] = callback;
              __pm_send_request_begin(
                id,
                JSON.stringify({ url: url, method: method, header: header, body: body }));
            },
          };
          // The legacy postman.* API: collections authored against old
          // Postman versions import against these; the aliases route
          // through the same pm surface.
          globalThis.postman = {
            getEnvironmentVariable: function (name) {
              return globalThis.pm.environment.get(name);
            },
            setEnvironmentVariable: function (name, value) {
              globalThis.pm.environment.set(name, value);
            },
            clearEnvironmentVariable: function (name) {
              globalThis.pm.environment.unset(name);
            },
            getCollectionVariable: function (name) {
              return globalThis.pm.collectionVariables.get(name);
            },
            getGlobalVariable: function (name) {
              return globalThis.pm.globals.get(name);
            },
            setGlobalVariable: function (name, value) {
              globalThis.pm.globals.set(name, value);
            },
            clearGlobalVariable: function (name) {
              globalThis.pm.globals.unset(name);
            },
            clearGlobalVariables: function () {
              Object.keys(globalThis.pm.globals.toObject()).forEach(function (name) {
                globalThis.pm.globals.unset(name);
              });
            },
            setNextRequest: function () {
              throw new Error(
                "postman.setNextRequest requires the collection runner, which is not available");
            },
          };
          // pm.sendRequest delivery: looks up the registered callback,
          // builds (err, response) - the response speaks the same pm
          // surface (code/headers/text/json) - and calls it. Callback
          // throws land in the console, never in the engine.
          globalThis.__pm_deliver_send_response = function () {
            var delivery = globalThis.__pm_delivery;
            delete globalThis.__pm_delivery;
            if (!delivery) { return; }
            var callback = globalThis["__pm_send_cb_" + delivery.id];
            if (typeof callback !== "function") { return; }
            var err = delivery.error == null ? null : delivery.error;
            var resp = delivery.response == null ? null : pmResponse(delivery.response);
            try {
              callback(err, resp);
            } catch (error) {
              console.error(
                "pm.sendRequest callback error: "
                + (error && error.message ? error.message : String(error)));
            }
          };
        }

        function pmTest(name, fn) {
          if (typeof fn !== "function") {
            throw new TypeError("pm.test expects (name, function)");
          }
          try {
            fn();
            __pm_state.results.push({ name: __pm_cap(String(name)), status: "passed", message: null });
          } catch (error) {
            var message =
              error && typeof error.message === "string" && error.message
                ? error.message
                : String(error);
            __pm_state.results.push(
              { name: __pm_cap(String(name)), status: "failed", message: __pm_cap(message) });
          }
        }

        // Postman's skip: registers a test under its name without running
        // its assertions (skipped tests still land in the results list).
        pmTest.skip = function (name) {
          __pm_state.results.push({ name: __pm_cap(String(name)), status: "skipped", message: null });
        };

        function expect(value) {
          var flags = { negated: false, deep: false };

          function fail(message) { throw new PMAssertionError(message); }

          function check(passes, message, negatedMessage) {
            if (flags.negated) {
              if (passes) { fail(negatedMessage); }
            } else if (!passes) { fail(message); }
          }

          var chain = {
            get to() { return chain; },
            get be() { return chain; },
            get been() { return chain; },
            get is() { return chain; },
            get that() { return chain; },
            get which() { return chain; },
            get and() { return chain; },
            get has() { return chain; },
            get have() { return chain; },
            get of() { return chain; },
            get at() { return chain; },
            // Postman spells these through the `at` step: to.be.at.least(n)
            // / to.be.at.most(n). The camelCase functions stay for direct
            // calls.
            get least() { return chain.atLeast; },
            get most() { return chain.atMost; },
            get does() { return chain; },
            get deep() { flags.deep = true; return chain; },
            get with() { return chain; },
            get not() { flags.negated = !flags.negated; return chain; },

            get true() {
              check(
                value === true,
                "expected " + __pm_show(value) + " to be true",
                "expected " + __pm_show(value) + " not to be true");
              return chain;
            },
            get false() {
              check(
                value === false,
                "expected " + __pm_show(value) + " to be false",
                "expected " + __pm_show(value) + " not to be false");
              return chain;
            },
            get ok() {
              check(
                !!value,
                "expected " + __pm_show(value) + " to be truthy",
                "expected " + __pm_show(value) + " to be falsy");
              return chain;
            },
            get null() {
              check(
                value === null,
                "expected " + __pm_show(value) + " to be null",
                "expected " + __pm_show(value) + " not to be null");
              return chain;
            },
            get undefined() {
              check(
                value === undefined,
                "expected " + __pm_show(value) + " to be undefined",
                "expected " + __pm_show(value) + " not to be undefined");
              return chain;
            },
            get NaN() {
              check(
                Number.isNaN(value),
                "expected " + __pm_show(value) + " to be NaN",
                "expected " + __pm_show(value) + " not to be NaN");
              return chain;
            },
            get exist() {
              check(
                value !== null && value !== undefined,
                "expected " + __pm_show(value) + " to exist",
                "expected " + __pm_show(value) + " not to exist");
              return chain;
            },
            get empty() {
              check(
                isEmptyValue(value),
                "expected " + __pm_show(value) + " to be empty",
                "expected " + __pm_show(value) + " not to be empty");
              return chain;
            },

            eql: function (expected) {
              check(
                deepEqual(value, expected),
                "expected " + __pm_show(value) + " to deeply equal " + __pm_show(expected),
                "expected " + __pm_show(value) + " not to deeply equal " + __pm_show(expected));
              return chain;
            },
            equal: function (expected) {
              check(
                (flags.deep ? deepEqual : Object.is)(value, expected),
                "expected " + __pm_show(value) + " to equal " + __pm_show(expected),
                "expected " + __pm_show(value) + " not to equal " + __pm_show(expected));
              return chain;
            },
            a: function (kind) {
              check(
                typeOf(value) === kind,
                "expected " + __pm_show(value) + " to be a " + kind,
                "expected " + __pm_show(value) + " not to be a " + kind);
              return chain;
            },
            an: function (kind) { return chain.a(kind); },
            above: function (bound) {
              check(
                typeof value === "number" && value > bound,
                "expected " + __pm_show(value) + " to be above " + bound,
                "expected " + __pm_show(value) + " not to be above " + bound);
              return chain;
            },
            below: function (bound) {
              check(
                typeof value === "number" && value < bound,
                "expected " + __pm_show(value) + " to be below " + bound,
                "expected " + __pm_show(value) + " not to be below " + bound);
              return chain;
            },
            atLeast: function (bound) {
              check(
                typeof value === "number" && value >= bound,
                "expected " + __pm_show(value) + " to be at least " + bound,
                "expected " + __pm_show(value) + " to be below " + bound);
              return chain;
            },
            atMost: function (bound) {
              check(
                typeof value === "number" && value <= bound,
                "expected " + __pm_show(value) + " to be at most " + bound,
                "expected " + __pm_show(value) + " to be above " + bound);
              return chain;
            },
            include: function (expected) {
              var pass =
                flags.deep
                ? (Array.isArray(value)
                    ? value.some(function (item) { return deepEqual(item, expected); })
                    : listHas(value, expected))
                : listHas(value, expected);
              check(
                pass,
                "expected " + __pm_show(value) + " to include " + __pm_show(expected),
                "expected " + __pm_show(value) + " not to include " + __pm_show(expected));
              return chain;
              return chain;
            },
            // chai spells inclusion three ways; Postman scripts use all of
            // them (.to.include / .to.contain / .to.includes).
            contains: function (expected) { return chain.include(expected); },
            contain: function (expected) { return chain.include(expected); },
            includes: function (expected) { return chain.include(expected); },
            // chai's .deep.members(list): every expected item deep-matches
            // some array element (and lengths match for a strict subset
            // check is NOT required by chai here - superset passes).
            members: function (list) {
              var pass = Array.isArray(value) && Array.isArray(list)
                && list.every(function (expected) {
                  return value.some(function (item) { return deepEqual(item, expected); });
                });
              check(
                pass,
                "expected " + __pm_show(value) + " to have members " + __pm_show(list),
                "expected " + __pm_show(value) + " not to have members " + __pm_show(list));
              return chain;
            },
            string: function (text) {
              check(
                typeof value === "string" && value.indexOf(text) !== -1,
                "expected " + __pm_show(value) + " to contain " + __pm_show(text),
                "expected " + __pm_show(value) + " not to contain " + __pm_show(text));
              return chain;
            },
            property: function (name, expectedValue) {
              var label = String(name);
              var present = hasProperty(value, name);
              if (expectedValue === undefined) {
                check(
                  present,
                  "expected " + __pm_show(value) + " to have property " + label,
                  "expected " + __pm_show(value) + " not to have property " + label);
              } else {
                check(
                  present && deepEqual(value[name], expectedValue),
                  "expected " + __pm_show(value) + " to have property " + label
                    + " of " + __pm_show(expectedValue),
                  "expected " + __pm_show(value) + " not to have property " + label
                    + " of " + __pm_show(expectedValue));
              }
              return chain;
            },
            match: function (pattern) {
              check(
                typeof value === "string" && pattern.test(value),
                "expected " + __pm_show(value) + " to match " + pattern,
                "expected " + __pm_show(value) + " not to match " + pattern);
              return chain;
            },
            lengthOf: function (length) {
              check(
                value !== null && value !== undefined && value.length === length,
                "expected " + __pm_show(value) + " to have a length of " + length
                  + " but got " + (value === null || value === undefined ? 0 : value.length),
                "expected " + __pm_show(value) + " not to have a length of " + length);
              return chain;
            },
            oneOf: function (list) {
              check(
                Array.isArray(list)
                  && list.some(function (item) { return deepEqual(item, value); }),
                "expected " + __pm_show(value) + " to be one of " + __pm_show(list),
                "expected " + __pm_show(value) + " not to be one of " + __pm_show(list));
              return chain;
            },
            instanceOf: function (ctor) {
              var name = ctor && typeof ctor === "function" && ctor.name ? ctor.name : String(ctor);
              check(
                typeof ctor === "function" && value instanceof ctor,
                "expected " + __pm_show(value) + " to be an instance of " + name,
                "expected " + __pm_show(value) + " not to be an instance of " + name);
              return chain;
            },
            fail: function (message) {
              fail(typeof message === "string" ? message : "expect.fail");
            },
          };
          // chai-style callable chaining: assertion functions carry the
          // chain's getters on their prototype, so
          // `.to.include.deep.members(...)` resolves through the function
          // object itself instead of dead-ending on it.
          var chainProto = {};
          ["to", "be", "been", "is", "that", "which", "and", "has", "have",
           "with", "at", "does", "deep"].forEach(function (key) {
            Object.defineProperty(chainProto, key, {
              get: function () { return chain; },
              configurable: true,
            });
          });
          // Wire the prototypes WITHOUT reading chain's properties: the
          // getters have side effects (.not flips negation, .ok asserts) and
          // must not fire during wiring. getOwnPropertyNames + descriptors
          // only touch function-valued data properties.
          Object.getOwnPropertyNames(chain).forEach(function (key) {
            var descriptor = Object.getOwnPropertyDescriptor(chain, key);
            if (descriptor && typeof descriptor.value === "function") {
              Object.setPrototypeOf(descriptor.value, chainProto);
            }
          });
          return chain;
        }

        function typeOf(value) {
          if (value === null) { return "null"; }
          if (Array.isArray(value)) { return "array"; }
          if (value instanceof RegExp) { return "regexp"; }
          if (value instanceof Date) { return "date"; }
          return typeof value;
        }

        function isEmptyValue(value) {
          if (value === null || value === undefined) { return true; }
          if (typeof value === "string" || Array.isArray(value)) { return value.length === 0; }
          if (typeof value === "object") { return Object.keys(value).length === 0; }
          return false;
        }

        function hasProperty(value, name) {
          if (value === null || value === undefined) { return false; }
          var key = String(name);
          return key in Object(value);
        }

        function listHas(value, expected) {
          if (typeof value === "string") {
            return typeof expected === "string" && value.indexOf(expected) !== -1;
          }
          if (Array.isArray(value)) {
            return value.some(function (item) { return deepEqual(item, expected); });
          }
          if (typeof value === "object" && value !== null
              && typeof expected === "object" && expected !== null) {
            return Object.keys(expected).every(function (key) {
              return deepEqual(value[key], expected[key]);
            });
          }
          return false;
        }

        function deepEqual(a, b) {
          if (Object.is(a, b)) { return true; }
          if (typeof a !== "object" || typeof b !== "object" || a === null || b === null) {
            return false;
          }
          if (Array.isArray(a) !== Array.isArray(b)) { return false; }
          var keysA = Object.keys(a), keysB = Object.keys(b);
          if (keysA.length !== keysB.length) { return false; }
          for (var i = 0; i < keysA.length; i++) {
            if (!deepEqual(a[keysA[i]], b[keysA[i]])) { return false; }
          }
          return true;
        }

        globalThis.console = {
          log: function () { __pm_push_log("log", arguments); },
          info: function () { __pm_push_log("log", arguments); },
          warn: function () { __pm_push_log("warn", arguments); },
          error: function () { __pm_push_log("error", arguments); },
        };

        globalThis.expect.fail = function (message) {
          throw new PMAssertionError(
            typeof message === "string" ? message : "expect.fail");
        };
        """
}
