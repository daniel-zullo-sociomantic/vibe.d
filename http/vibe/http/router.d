/**
	Pattern based URL router for HTTP request.

	See `URLRouter` for more details.

	Copyright: © 2012-2015 RejectedSoftware e.K.
	License: Subject to the terms of the MIT license, as written in the included LICENSE.txt file.
	Authors: Sönke Ludwig
*/
module vibe.http.router;

public import vibe.http.server;

import vibe.core.log;

import std.functional;


/**
	Routes HTTP requests based on the request method and URL.

	Routes are matched using a special URL match string that supports two forms
	of placeholders. See the sections below for more details.

	Registered routes are matched according to the same sequence as initially
	specified using `match`, `get`, `post` etc. Matching ends as soon as a route
	handler writes a response using `res.writeBody()` or similar means. If no
	route matches or if no route handler writes a response, the router will
	simply not handle the request and the HTTP server will automatically
	generate a 404 error.

	Match_patterns:
		Match patterns are character sequences that can optionally contain
		placeholders or raw wildcards ("*"). Raw wild cards match any character
		sequence, while placeholders match only sequences containing no slash
		("/") characters.

		Placeholders are started using a colon (":") and are directly followed
		by their name. The first "/" character (or the end of the match string)
		denotes the end of the placeholder name. The part of the string that
		matches a placeholder will be stored in the `HTTPServerRequest.params`
		map using the placeholder name as the key.

		Match strings are subject to the following rules:
		$(UL
			$(LI A raw wildcard ("*") may only occur at the end of the match string)
			$(LI At least one character must be placed between any two placeholders or wildcards)
			$(LI The maximum allowed number of placeholders in a single match string is 64)
		)

	Match_String_Examples:
		$(UL
			$(LI `"/foo/bar"` matches only `"/foo/bar"` itself)
			$(LI `"/foo/*"` matches `"/foo/"`, `"/foo/bar"`, `"/foo/bar/baz"` or _any other string beginning with `"/foo/"`)
			$(LI `"/:x/"` matches `"/foo/"`, `"/bar/"` and similar strings (and stores `"foo"`/`"bar"` in `req.params["x"]`), but not `"/foo/bar/"`)
			$(LI Matching partial path entries with wildcards is possible: `"/foo:x"` matches `"/foo"`, `"/foobar"`, but not `"/foo/bar"`)
			$(LI Multiple placeholders and raw wildcards can be combined: `"/:x/:y/*"`)
		)
*/
final class URLRouter : HTTPServerRequestHandler {
	@safe:

	private {
		MatchTree!Route m_routes;
		string m_prefix;
		bool m_computeBasePath;
	}

	this(string prefix = null)
	{
		m_prefix = prefix;
	}

	/** Sets a common prefix for all registered routes.

		All routes will implicitly have this prefix prepended before being
		matched against incoming requests.
	*/
	@property string prefix() const { return m_prefix; }

	/** Controls the computation of the "routerRootDir" parameter.

		This parameter is available as `req.params["routerRootDir"]` and
		contains the relative path to the base path of the router. The base
		path is determined by the `prefix` property.

		Note that this feature currently is requires dynamic memory allocations
		and is opt-in for this reason.
	*/
	@property void enableRootDir(bool enable) { m_computeBasePath = enable; }

	/// Returns a single route handle to conveniently register multiple methods.
	URLRoute route(string path)
	in { assert(path.length, "Cannot register null or empty path!"); }
	body { return URLRoute(this, path); }

	///
	unittest {
		void getFoo(scope HTTPServerRequest req, scope HTTPServerResponse res) { /* ... */ }
		void postFoo(scope HTTPServerRequest req, scope HTTPServerResponse res) { /* ... */ }
		void deleteFoo(scope HTTPServerRequest req, scope HTTPServerResponse res) { /* ... */ }

		auto r = new URLRouter;

		// using 'with' statement
		with (r.route("/foo")) {
			get(&getFoo);
			post(&postFoo);
			delete_(&deleteFoo);
		}

		// using method chaining
		r.route("/foo")
			.get(&getFoo)
			.post(&postFoo)
			.delete_(&deleteFoo);

		// without using route()
		r.get("/foo", &getFoo);
		r.post("/foo", &postFoo);
		r.delete_("/foo", &deleteFoo);
	}

	/// Adds a new route for requests matching the specified HTTP method and pattern.
	URLRouter match(Handler)(HTTPMethod method, string path, Handler handler)
		if (isValidHandler!Handler)
	{
		import std.algorithm;
		assert(path.length, "Cannot register null or empty path!");
		assert(count(path, ':') <= maxRouteParameters, "Too many route parameters");
		logDebug("add route %s %s", method, path);
		m_routes.addTerminal(path, Route(method, path, handlerDelegate(handler)));
		return this;
	}

	/// Adds a new route for GET requests matching the specified pattern.
	URLRouter get(Handler)(string url_match, Handler handler) if (isValidHandler!Handler) { return match(HTTPMethod.GET, url_match, handler); }
	/// ditto
	URLRouter get(string url_match, HTTPServerRequestDelegate handler) { return match(HTTPMethod.GET, url_match, handler); }

	/// Adds a new route for POST requests matching the specified pattern.
	URLRouter post(Handler)(string url_match, Handler handler) if (isValidHandler!Handler) { return match(HTTPMethod.POST, url_match, handler); }
	/// ditto
	URLRouter post(string url_match, HTTPServerRequestDelegate handler) { return match(HTTPMethod.POST, url_match, handler); }

	/// Adds a new route for PUT requests matching the specified pattern.
	URLRouter put(Handler)(string url_match, Handler handler) if (isValidHandler!Handler) { return match(HTTPMethod.PUT, url_match, handler); }
	/// ditto
	URLRouter put(string url_match, HTTPServerRequestDelegate handler) { return match(HTTPMethod.PUT, url_match, handler); }

	/// Adds a new route for DELETE requests matching the specified pattern.
	URLRouter delete_(Handler)(string url_match, Handler handler) if (isValidHandler!Handler) { return match(HTTPMethod.DELETE, url_match, handler); }
	/// ditto
	URLRouter delete_(string url_match, HTTPServerRequestDelegate handler) { return match(HTTPMethod.DELETE, url_match, handler); }

	/// Adds a new route for PATCH requests matching the specified pattern.
	URLRouter patch(Handler)(string url_match, Handler handler) if (isValidHandler!Handler) { return match(HTTPMethod.PATCH, url_match, handler); }
	/// ditto
	URLRouter patch(string url_match, HTTPServerRequestDelegate handler) { return match(HTTPMethod.PATCH, url_match, handler); }

	/// Adds a new route for requests matching the specified pattern, regardless of their HTTP verb.
	URLRouter any(Handler)(string url_match, Handler handler)
	{
		import std.traits;
		static HTTPMethod[] all_methods = [EnumMembers!HTTPMethod];
		foreach(immutable method; all_methods)
			match(method, url_match, handler);

		return this;
	}
	/// ditto
	URLRouter any(string url_match, HTTPServerRequestDelegate handler) { return any!HTTPServerRequestDelegate(url_match, handler); }


	/** Rebuilds the internal matching structures to account for newly added routes.

		This should be used after a lot of routes have been added to the router, to
		force eager computation of the match structures. The alternative is to
		let the router lazily compute the structures when the first request happens,
		which can delay this request.
	*/
	void rebuild()
	{
		m_routes.rebuildGraph();
	}

	/// Handles a HTTP request by dispatching it to the registered route handlers.
	void handleRequest(HTTPServerRequest req, HTTPServerResponse res)
	{
		auto method = req.method;

		string calcBasePath()
		@safe {
			import vibe.inet.path;
			auto p = InetPath(prefix.length ? prefix : "/");
			p.endsWithSlash = true;
			return p.relativeToWeb(InetPath(req.path)).toString();
		}

		auto path = req.path;
		if (path.length < m_prefix.length || path[0 .. m_prefix.length] != m_prefix) return;
		path = path[m_prefix.length .. $];

		while (true) {
			bool done = m_routes.match(path, (ridx, scope values) @safe {
				auto r = () @trusted { return &m_routes.getTerminalData(ridx); } ();
				if (r.method != method) return false;

				logDebugV("route match: %s -> %s %s %s", req.path, r.method, r.pattern, values);
				foreach (i, v; values) req.params[m_routes.getTerminalVarNames(ridx)[i]] = v;
				if (m_computeBasePath) req.params["routerRootDir"] = calcBasePath();
				r.cb(req, res);
				return res.headerWritten;
			});
			if (done) return;

			if (method == HTTPMethod.HEAD) method = HTTPMethod.GET;
			else break;
		}

		logDebug("no route match: %s %s", req.method, req.requestURL);
	}

	/// Returns all registered routes as const AA
	const(Route)[] getAllRoutes()
	{
		auto routes = new Route[m_routes.terminalCount];
		foreach (i, ref r; routes)
			r = m_routes.getTerminalData(i);
		return routes;
	}

	template isValidHandler(Handler) {
		@system {
			alias USDel = void delegate(HTTPServerRequest, HTTPServerResponse) @system;
			alias USFun = void function(HTTPServerRequest, HTTPServerResponse) @system;
			alias USDelS = void delegate(scope HTTPServerRequest, scope HTTPServerResponse) @system;
			alias USFunS = void function(scope HTTPServerRequest, scope HTTPServerResponse) @system;
		}

		static if (
				is(Handler : HTTPServerRequestDelegate) ||
				is(Handler : HTTPServerRequestFunction) ||
				is(Handler : HTTPServerRequestHandler) ||
				is(Handler : HTTPServerRequestDelegateS) ||
				is(Handler : HTTPServerRequestFunctionS) ||
				is(Handler : HTTPServerRequestHandlerS)
			)
		{
			enum isValidHandler = true;
		} else static if (
				is(Handler : USDel) || is(Handler : USFun) ||
				is(Handler : USDelS) || is(Handler : USFunS)
			)
		{
			enum isValidHandler = true;
		} else {
			enum isValidHandler = false;
		}
	}

	static void delegate(HTTPServerRequest, HTTPServerResponse) @safe handlerDelegate(Handler)(Handler handler)
	{
		import std.traits : isFunctionPointer;
		static if (isFunctionPointer!Handler) return handlerDelegate(() @trusted { return toDelegate(handler); } ());
		else static if (is(Handler == class) || is(Handler == interface)) return &handler.handleRequest;
		else static if (__traits(compiles, () @safe { handler(HTTPServerRequest.init, HTTPServerResponse.init); } ())) return handler;
		else return (req, res) @trusted { handler(req, res); };
	}

	unittest {
		static assert(isValidHandler!HTTPServerRequestFunction);
		static assert(isValidHandler!HTTPServerRequestDelegate);
		static assert(isValidHandler!HTTPServerRequestHandler);
		static assert(isValidHandler!HTTPServerRequestFunctionS);
		static assert(isValidHandler!HTTPServerRequestDelegateS);
		static assert(isValidHandler!HTTPServerRequestHandlerS);
		static assert(isValidHandler!(void delegate(HTTPServerRequest req, HTTPServerResponse res) @system));
		static assert(isValidHandler!(void function(HTTPServerRequest req, HTTPServerResponse res) @system));
		static assert(isValidHandler!(void delegate(scope HTTPServerRequest req, scope HTTPServerResponse res) @system));
		static assert(isValidHandler!(void function(scope HTTPServerRequest req, scope HTTPServerResponse res) @system));
		static assert(!isValidHandler!(int delegate(HTTPServerRequest req, HTTPServerResponse res) @system));
		static assert(!isValidHandler!(int delegate(HTTPServerRequest req, HTTPServerResponse res) @safe));
		void test(H)(H h)
		{
			static assert(isValidHandler!H);
		}
		test((HTTPServerRequest req, HTTPServerResponse res) {});
	}
}

///
@safe unittest {
	import vibe.http.fileserver;

	void addGroup(HTTPServerRequest req, HTTPServerResponse res)
	{
		// Route variables are accessible via the params map
		logInfo("Getting group %s for user %s.", req.params["groupname"], req.params["username"]);
	}

	void deleteUser(HTTPServerRequest req, HTTPServerResponse res)
	{
		// ...
	}

	void auth(HTTPServerRequest req, HTTPServerResponse res)
	{
		// TODO: check req.session to see if a user is logged in and
		//       write an error page or throw an exception instead.
	}

	void setup()
	{
		auto router = new URLRouter;
		// Matches all GET requests for /users/*/groups/* and places
		// the place holders in req.params as 'username' and 'groupname'.
		router.get("/users/:username/groups/:groupname", &addGroup);

		// Matches all requests. This can be useful for authorization and
		// similar tasks. The auth method will only write a response if the
		// user is _not_ authorized. Otherwise, the router will fall through
		// and continue with the following routes.
		router.any("*", &auth);

		// Matches a POST request
		router.post("/users/:username/delete", &deleteUser);

		// Matches all GET requests in /static/ such as /static/img.png or
		// /static/styles/sty.css
		router.get("/static/*", serveStaticFiles("public/"));

		// Setup a HTTP server...
		auto settings = new HTTPServerSettings;
		// ...

		// The router can be directly passed to the listenHTTP function as
		// the main request handler.
		listenHTTP(settings, router);
	}
}

/** Using nested routers to map components to different sub paths. A component
	could for example be an embedded blog engine.
*/
@safe unittest {
	// some embedded component:

	void showComponentHome(HTTPServerRequest req, HTTPServerResponse res)
	{
		// ...
	}

	void showComponentUser(HTTPServerRequest req, HTTPServerResponse res)
	{
		// ...
	}

	void registerComponent(URLRouter router)
	{
		router.get("/", &showComponentHome);
		router.get("/users/:user", &showComponentUser);
	}

	// main application:

	void showHome(HTTPServerRequest req, HTTPServerResponse res)
	{
		// ...
	}

	void setup()
	{
		auto c1router = new URLRouter("/component1");
		registerComponent(c1router);

		auto mainrouter = new URLRouter;
		mainrouter.get("/", &showHome);
		// forward all unprocessed requests to the component router
		mainrouter.any("*", c1router);

		// now the following routes will be matched:
		// / -> showHome
		// /component1/ -> showComponentHome
		// /component1/users/:user -> showComponentUser

		// Start the HTTP server
		auto settings = new HTTPServerSettings;
		// ...
		listenHTTP(settings, mainrouter);
	}
}

@safe unittest { // issue #1668
	auto r = new URLRouter;
	r.get("/", (req, res) {
		if ("foo" in req.headers)
			res.writeBody("bar");
	});

	r.get("/", (scope req, scope res) {
		if ("foo" in req.headers)
			res.writeBody("bar");
	});
	r.get("/", (req, res) {});
	r.post("/", (req, res) {});
	r.put("/", (req, res) {});
	r.delete_("/", (req, res) {});
	r.patch("/", (req, res) {});
	r.any("/", (req, res) {});
}

@safe unittest {
	import vibe.inet.url;

	auto router = new URLRouter;
	string result;
	void a(HTTPServerRequest req, HTTPServerResponse) { result ~= "A"; }
	void b(HTTPServerRequest req, HTTPServerResponse) { result ~= "B"; }
	void c(HTTPServerRequest req, HTTPServerResponse) { assert(req.params["test"] == "x", "Wrong variable contents: "~req.params["test"]); result ~= "C"; }
	void d(HTTPServerRequest req, HTTPServerResponse) { assert(req.params["test"] == "y", "Wrong variable contents: "~req.params["test"]); result ~= "D"; }
	router.get("/test", &a);
	router.post("/test", &b);
	router.get("/a/:test", &c);
	router.get("/a/:test/", &d);

	auto res = createTestHTTPServerResponse();
	router.handleRequest(createTestHTTPServerRequest(URL("http://localhost/")), res);
	assert(result == "", "Matched for non-existent / path");
	router.handleRequest(createTestHTTPServerRequest(URL("http://localhost/test")), res);
	assert(result == "A", "Didn't match a simple GET request");
	router.handleRequest(createTestHTTPServerRequest(URL("http://localhost/test"), HTTPMethod.POST), res);
	assert(result == "AB", "Didn't match a simple POST request");
	router.handleRequest(createTestHTTPServerRequest(URL("http://localhost/a/"), HTTPMethod.GET), res);
	assert(result == "AB", "Matched empty variable. "~result);
	router.handleRequest(createTestHTTPServerRequest(URL("http://localhost/a/x"), HTTPMethod.GET), res);
	assert(result == "ABC", "Didn't match a trailing 1-character var.");
	// currently fails due to Path not accepting "//"
	//router.handleRequest(createTestHTTPServerRequest(URL("http://localhost/a//"), HTTPMethod.GET), res);
	//assert(result == "ABC", "Matched empty string or slash as var. "~result);
	router.handleRequest(createTestHTTPServerRequest(URL("http://localhost/a/y/"), HTTPMethod.GET), res);
	assert(result == "ABCD", "Didn't match 1-character infix variable.");
}

@safe unittest {
	import vibe.inet.url;

	auto router = new URLRouter("/test");

	string result;
	void a(HTTPServerRequest req, HTTPServerResponse) { result ~= "A"; }
	void b(HTTPServerRequest req, HTTPServerResponse) { result ~= "B"; }
	router.get("/x", &a);
	router.get("/y", &b);

	auto res = createTestHTTPServerResponse();
	router.handleRequest(createTestHTTPServerRequest(URL("http://localhost/test")), res);
	assert(result == "");
	router.handleRequest(createTestHTTPServerRequest(URL("http://localhost/test/x")), res);
	assert(result == "A");
	router.handleRequest(createTestHTTPServerRequest(URL("http://localhost/test/y")), res);
	assert(result == "AB");
}


/**
	Convenience abstraction for a single `URLRouter` route.

	See `URLRouter.route` for a usage example.
*/
struct URLRoute {
@safe:

	URLRouter router;
	string path;

	ref URLRoute get(Handler)(Handler h) { router.get(path, h); return this; }
	ref URLRoute post(Handler)(Handler h) { router.post(path, h); return this; }
	ref URLRoute put(Handler)(Handler h) { router.put(path, h); return this; }
	ref URLRoute delete_(Handler)(Handler h) { router.delete_(path, h); return this; }
	ref URLRoute patch(Handler)(Handler h) { router.patch(path, h); return this; }
	ref URLRoute any(Handler)(Handler h) { router.any(path, h); return this; }
	ref URLRoute match(Handler)(HTTPMethod method, Handler h) { router.match(method, path, h); return this; }
}


private enum maxRouteParameters = 64;

private struct Route {
	HTTPMethod method;
	string pattern;
	HTTPServerRequestDelegate cb;
}

private string skipPathNode(string str, ref size_t idx)
@safe {
	size_t start = idx;
	while( idx < str.length && str[idx] != '/' ) idx++;
	return str[start .. idx];
}

private string skipPathNode(ref string str)
@safe {
	size_t idx = 0;
	auto ret = skipPathNode(str, idx);
	str = str[idx .. $];
	return ret;
}

private struct MatchTree(T) {
@safe:

	import std.algorithm : countUntil;
	import std.array : array;

	private {
		struct Node {
			size_t terminalsStart; // slice into m_terminalTags
			size_t terminalsEnd;
			uint[ubyte.max+1] edges = uint.max; // character -> index into m_nodes
		}
		struct TerminalTag {
			size_t index; // index into m_terminals array
			size_t var; // index into Terminal.varNames/varValues or size_t.max
		}
		struct Terminal {
			string pattern;
			T data;
			string[] varNames;
			size_t[size_t] varMap; // maps node index to variable index
		}
		Node[] m_nodes; // all nodes as a single array
		TerminalTag[] m_terminalTags;
		Terminal[] m_terminals;

		enum TerminalChar = 0;
		bool m_upToDate = false;
	}

	@property size_t terminalCount() const { return m_terminals.length; }

	void addTerminal(string pattern, T data)
	{
		m_terminals ~= Terminal(pattern, data, null, null);
		m_upToDate = false;
	}

	bool match(string text, scope bool delegate(size_t terminal, scope string[] vars) @safe del)
	{
		// lazily update the match graph
		if (!m_upToDate) rebuildGraph();

		return doMatch(text, del);
	}

	const(string)[] getTerminalVarNames(size_t terminal) const { return m_terminals[terminal].varNames; }
	ref inout(T) getTerminalData(size_t terminal) inout { return m_terminals[terminal].data; }

	void print()
	const {
		import std.algorithm : map;
		import std.array : join;
		import std.conv : to;
		import std.range : iota;
		import std.string : format;

		logInfo("Nodes:");
		foreach (i, n; m_nodes) {
			logInfo("  %s %s", i, m_terminalTags[n.terminalsStart .. n.terminalsEnd]
				.map!(t => format("T%s%s", t.index, t.var != size_t.max ? "("~m_terminals[t.index].varNames[t.var]~")" : "")).join(" "));
			//logInfo("  %s %s-%s", i, n.terminalsStart, n.terminalsEnd);


			static string mapChar(ubyte ch) {
				if (ch == TerminalChar) return "$";
				if (ch >= '0' && ch <= '9') return to!string(cast(dchar)ch);
				if (ch >= 'a' && ch <= 'z') return to!string(cast(dchar)ch);
				if (ch >= 'A' && ch <= 'Z') return to!string(cast(dchar)ch);
				if (ch == '/') return "/";
				if (ch == '^') return "^";
				return ch.to!string;
			}

			void printRange(uint node, ubyte from, ubyte to)
			{
				if (to - from <= 10) logInfo("    %s -> %s", iota(from, cast(uint)to+1).map!(ch => mapChar(cast(ubyte)ch)).join("|"), node);
				else logInfo("    %s-%s -> %s", mapChar(from), mapChar(to), node);
			}

			uint last_to = uint.max;
			ubyte last_ch = 0;
			foreach (ch, e; n.edges)
				if (e != last_to) {
					if (last_to != uint.max)
						printRange(last_to, last_ch, cast(ubyte)(ch-1));
					last_ch = cast(ubyte)ch;
					last_to = e;
				}
			if (last_to != uint.max)
				printRange(last_to, last_ch, ubyte.max);
		}
	}

	private bool doMatch(string text, scope bool delegate(size_t terminal, scope string[] vars) @safe del)
	const {
		string[maxRouteParameters] vars_buf;// = void;

		import std.algorithm : canFind;

		// first, determine the end node, if any
		auto n = matchTerminals(text);
		if (!n) return false;

		// then, go through the terminals and match their variables
		foreach (ref t; m_terminalTags[n.terminalsStart .. n.terminalsEnd]) {
			auto term = &m_terminals[t.index];
			auto vars = vars_buf[0 .. term.varNames.length];
			matchVars(vars, term, text);
			if (vars.canFind!(v => v.length == 0)) continue; // all variables must be non-empty to match
			if (del(t.index, vars)) return true;
		}
		return false;
	}

	private inout(Node)* matchTerminals(string text)
	inout {
		if (!m_nodes.length) return null;

		auto n = &m_nodes[0];

		// follow the path through the match graph
		foreach (i, char ch; text) {
			auto nidx = n.edges[cast(size_t)ch];
			if (nidx == uint.max) return null;
			n = &m_nodes[nidx];
		}

		// finally, find a matching terminal node
		auto nidx = n.edges[TerminalChar];
		if (nidx == uint.max) return null;
		n = &m_nodes[nidx];
		return n;
	}

	private void matchVars(string[] dst, in Terminal* term, string text)
	const {
		auto nidx = 0;
		size_t activevar = size_t.max;
		size_t activevarstart;

		dst[] = null;

		// folow the path throgh the match graph
		foreach (i, char ch; text) {
			auto var = term.varMap.get(nidx, size_t.max);

			// detect end of variable
			if (var != activevar && activevar != size_t.max) {
				dst[activevar] = text[activevarstart .. i-1];
				activevar = size_t.max;
			}

			// detect beginning of variable
			if (var != size_t.max && activevar == size_t.max) {
				activevar = var;
				activevarstart = i;
			}

			nidx = m_nodes[nidx].edges[cast(ubyte)ch];
			assert(nidx != uint.max);
		}

		// terminate any active varible with the end of the input string or with the last character
		auto var = term.varMap.get(nidx, size_t.max);
		if (activevar != size_t.max) dst[activevar] = text[activevarstart .. (var == activevar ? $ : $-1)];
	}

	private void rebuildGraph()
	{
		import std.array : appender;

		if (m_upToDate) return;
		m_upToDate = true;

		m_nodes = null;
		m_terminalTags = null;

		if (!m_terminals.length) return;

		MatchGraphBuilder builder;
		foreach (i, ref t; m_terminals)
			t.varNames = builder.insert(t.pattern, i);
		//builder.print();
		builder.disambiguate();

		auto nodemap = new uint[builder.m_nodes.length];
		nodemap[] = uint.max;

		auto nodes = appender!(Node[]);
		nodes.reserve(1024);

		uint process(size_t n)
		{
			import std.algorithm : canFind;

			if (nodemap[n] != uint.max) return nodemap[n];
			auto nmidx = cast(uint)nodes.data.length;
			nodemap[n] = nmidx;
			nodes.put(Node.init);

			Node nn;
			nn.terminalsStart = m_terminalTags.length;
			foreach (t; builder.m_nodes[n].terminals) {
				auto var = t.var.length ? m_terminals[t.index].varNames.countUntil(t.var) : size_t.max;
				assert(!m_terminalTags[nn.terminalsStart .. $].canFind!(u => u.index == t.index && u.var == var));
				m_terminalTags ~= TerminalTag(t.index, var);
				if (var != size_t.max)
					m_terminals[t.index].varMap[nmidx] = var;
			}
			nn.terminalsEnd = m_terminalTags.length;
			foreach (ch, targets; builder.m_nodes[n].edges)
				foreach (to; targets)
					nn.edges[ch] = process(to);

			nodes.data[nmidx] = nn;

			return nmidx;
		}
		assert(builder.m_nodes[0].edges['^'].length == 1, "Graph must be disambiguated before purging.");
		process(builder.m_nodes[0].edges['^'][0]);

		m_nodes = nodes.data;

		logDebug("Match tree has %s(%s) nodes, %s terminals", m_nodes.length, builder.m_nodes.length, m_terminals.length);
	}
}

unittest {
	import std.string : format;
	MatchTree!int m;

	void testMatch(string str, size_t[] terms, string[] vars)
	{
		size_t[] mterms;
		string[] mvars;
		m.match(str, (t, scope vals) {
			mterms ~= t;
			mvars ~= vals;
			return false;
		});
		assert(mterms == terms, format("Mismatched terminals: %s (expected %s)", mterms, terms));
		assert(mvars == vars, format("Mismatched variables; %s (expected %s)", mvars, vars));
	}

	m.addTerminal("a", 0);
	m.addTerminal("b", 0);
	m.addTerminal("ab", 0);
	m.rebuildGraph();
	assert(m.getTerminalVarNames(0) == []);
	assert(m.getTerminalVarNames(1) == []);
	assert(m.getTerminalVarNames(2) == []);
	testMatch("a", [0], []);
	testMatch("ab", [2], []);
	testMatch("abc", [], []);
	testMatch("b", [1], []);

	m = MatchTree!int.init;
	m.addTerminal("ab", 0);
	m.addTerminal("a*", 0);
	m.rebuildGraph();
	assert(m.getTerminalVarNames(0) == []);
	assert(m.getTerminalVarNames(1) == []);
	testMatch("a", [1], []);
	testMatch("ab", [0, 1], []);
	testMatch("abc", [1], []);

	m = MatchTree!int.init;
	m.addTerminal("ab", 0);
	m.addTerminal("a:var", 0);
	m.rebuildGraph();
	assert(m.getTerminalVarNames(0) == []);
	assert(m.getTerminalVarNames(1) == ["var"], format("%s", m.getTerminalVarNames(1)));
	testMatch("a", [], []); // vars may not be empty
	testMatch("ab", [0, 1], ["b"]);
	testMatch("abc", [1], ["bc"]);

	m = MatchTree!int.init;
	m.addTerminal(":var1/:var2", 0);
	m.addTerminal("a/:var3", 0);
	m.addTerminal(":var4/b", 0);
	m.rebuildGraph();
	assert(m.getTerminalVarNames(0) == ["var1", "var2"]);
	assert(m.getTerminalVarNames(1) == ["var3"]);
	assert(m.getTerminalVarNames(2) == ["var4"]);
	testMatch("a", [], []);
	testMatch("a/a", [0, 1], ["a", "a", "a"]);
	testMatch("a/b", [0, 1, 2], ["a", "b", "b", "a"]);
	testMatch("a/bc", [0, 1], ["a", "bc", "bc"]);
	testMatch("ab/b", [0, 2], ["ab", "b", "ab"]);
	testMatch("ab/bc", [0], ["ab", "bc"]);

	m = MatchTree!int.init;
	m.addTerminal(":var1/", 0);
	m.rebuildGraph();
	assert(m.getTerminalVarNames(0) == ["var1"]);
	testMatch("ab/", [0], ["ab"]);
	testMatch("ab", [], []);
	testMatch("/ab", [], []);
	testMatch("a/b", [], []);
	testMatch("ab//", [], []);
}


private struct MatchGraphBuilder {
@safe:

	import std.array : array;
	import std.algorithm : filter;
	import std.string : format;

	private {
		enum TerminalChar = 0;
		struct TerminalTag {
			size_t index;
			string var;
			bool opEquals(in ref TerminalTag other) const { return index == other.index && var == other.var; }
		}
		struct Node {
			size_t idx;
			TerminalTag[] terminals;
			size_t[][ubyte.max+1] edges;
		}
		Node[] m_nodes;
	}

	string[] insert(string pattern, size_t terminal)
	{
		import std.algorithm : canFind;

		auto full_pattern = pattern;
		string[] vars;
		if (!m_nodes.length) addNode();

		// create start node and connect to zero node
		auto nidx = addNode();
		addEdge(0, nidx, '^', terminal, null);

		while (pattern.length) {
			auto ch = pattern[0];
			if (ch == '*') {
				assert(pattern.length == 1, "Asterisk is only allowed at the end of a pattern: "~full_pattern);
				pattern = null;

				foreach (v; ubyte.min .. ubyte.max+1) {
					if (v == TerminalChar) continue;
					addEdge(nidx, nidx, cast(ubyte)v, terminal, null);
				}
			} else if (ch == ':') {
				pattern = pattern[1 .. $];
				auto name = skipPathNode(pattern);
				assert(name.length > 0, "Missing placeholder name: "~full_pattern);
				assert(!vars.canFind(name), "Duplicate placeholder name ':"~name~"': '"~full_pattern~"'");
				vars ~= name;
				assert(!pattern.length || (pattern[0] != '*' && pattern[0] != ':'),
					"Cannot have two placeholders directly follow each other.");

				foreach (v; ubyte.min .. ubyte.max+1) {
					if (v == TerminalChar || v == '/') continue;
					addEdge(nidx, nidx, cast(ubyte)v, terminal, name);
				}
			} else {
				nidx = addEdge(nidx, ch, terminal, null);
				pattern = pattern[1 .. $];
			}
		}

		addEdge(nidx, TerminalChar, terminal, null);
		return vars;
	}

	void disambiguate()
	{
		import std.algorithm : map, sum;
		import std.array : appender, join;

//logInfo("Disambiguate");
		if (!m_nodes.length) return;

		import vibe.utils.hashmap;
		HashMap!(size_t[], size_t) combined_nodes;
		auto visited = new bool[m_nodes.length * 2];
		Stack!size_t node_stack;
		node_stack.reserve(m_nodes.length);
		node_stack.push(0);
		while (!node_stack.empty) {
			auto n = node_stack.pop();

			while (n >= visited.length) visited.length = visited.length * 2;
			if (visited[n]) continue;
//logInfo("Disambiguate %s", n);
			visited[n] = true;

			foreach (ch_; ubyte.min .. ubyte.max+1) {
				ubyte ch = cast(ubyte)ch_;
				auto chnodes = m_nodes[n].edges[ch_];

				// handle trivial cases
				if (chnodes.length <= 1) continue;

				// generate combined state for ambiguous edges
				if (auto pn = () @trusted { return chnodes in combined_nodes; } ()) { m_nodes[n].edges[ch] = singleNodeArray(*pn); continue; }

				// for new combinations, create a new node
				size_t ncomb = addNode();
				combined_nodes[chnodes] = ncomb;

				// allocate memory for all edges combined
				size_t total_edge_count = 0;
				foreach (chn; chnodes) {
					Node* cn = &m_nodes[chn];
					foreach (edges; cn.edges)
						total_edge_count +=edges.length;
				}
				auto mem = new size_t[total_edge_count];

				// write all edges
				size_t idx = 0;
				foreach (to_ch; ubyte.min .. ubyte.max+1) {
					size_t start = idx;
					foreach (chn; chnodes) {
						auto edges = m_nodes[chn].edges[to_ch];
						mem[idx .. idx + edges.length] = edges;
						idx += edges.length;
					}
					m_nodes[ncomb].edges[to_ch] = mem[start .. idx];
				}

				// add terminal indices
				foreach (chn; chnodes) addToArray(m_nodes[ncomb].terminals, m_nodes[chn].terminals);
				foreach (i; 1 .. m_nodes[ncomb].terminals.length)
					assert(m_nodes[ncomb].terminals[0] != m_nodes[ncomb].terminals[i]);

				m_nodes[n].edges[ch] = singleNodeArray(ncomb);
			}

			// process nodes recursively
			foreach (ch; ubyte.min .. ubyte.max+1)
				node_stack.push(m_nodes[n].edges[ch]);
		}
		debug logDebug("Disambiguate done: %s nodes, %s max stack size", m_nodes.length, node_stack.maxSize);
	}

	void print()
	const {
		import std.algorithm : map;
		import std.array : join;
		import std.conv : to;
		import std.string : format;

		logInfo("Nodes:");
		foreach (i, n; m_nodes) {
			string mapChar(ubyte ch) {
				if (ch == TerminalChar) return "$";
				if (ch >= '0' && ch <= '9') return to!string(cast(dchar)ch);
				if (ch >= 'a' && ch <= 'z') return to!string(cast(dchar)ch);
				if (ch >= 'A' && ch <= 'Z') return to!string(cast(dchar)ch);
				if (ch == '/') return "/";
				return ch.to!string;
			}
			logInfo("  %s %s", i, n.terminals.map!(t => format("T%s%s", t.index, t.var.length ? "("~t.var~")" : "")).join(" "));
			foreach (ch, tnodes; n.edges)
				foreach (tn; tnodes)
					logInfo("    %s -> %s", mapChar(cast(ubyte)ch), tn);
		}
	}

	private void addEdge(size_t from, size_t to, ubyte ch, size_t terminal, string var)
	{
		auto e = &m_nodes[from].edges[ch];
		if (!(*e).length) *e = singleNodeArray(to);
		else *e ~= to;
		addTerminal(to, terminal, var);
	}

	private size_t addEdge(size_t from, ubyte ch, size_t terminal, string var)
	{
		import std.algorithm : canFind;
		import std.string : format;
		assert(!m_nodes[from].edges[ch].length > 0, format("%s is in %s", ch, m_nodes[from].edges));
		auto nidx = addNode();
		addEdge(from, nidx, ch, terminal, var);
		return nidx;
	}

	private void addTerminal(size_t node, size_t terminal, string var)
	{
		foreach (ref t; m_nodes[node].terminals) {
			if (t.index == terminal) {
				assert(t.var.length == 0 || t.var == var, "Ambiguous route var match!? '"~t.var~"' vs. '"~var~"'");
				t.var = var;
				return;
			}
		}
		m_nodes[node].terminals ~= TerminalTag(terminal, var);
	}

	private size_t addNode()
	{
		auto idx = m_nodes.length;
		m_nodes ~= Node(idx, null, null);
		return idx;
	}

	private size_t[] singleNodeArray(size_t node)
	@trusted {
		return (&m_nodes[node].idx)[0 .. 1];
	}

	private static addToArray(T)(ref T[] arr, T[] elems) { foreach (e; elems) addToArray(arr, e); }
	private static addToArray(T)(ref T[] arr, T elem)
	{
		import std.algorithm : canFind;
		if (!arr.canFind(elem)) arr ~= elem;
	}
}

private struct Stack(E)
{
	private {
		E[] m_storage;
		size_t m_fill;
		debug size_t m_maxFill;
	}

	@property bool empty() const { return m_fill == 0; }

	debug @property size_t maxSize() const { return m_maxFill; }

	void reserve(size_t amt)
	{
		auto minsz = m_fill + amt;
		if (m_storage.length < minsz) {
			auto newlength = 64;
			while (newlength < minsz) newlength *= 2;
			m_storage.length = newlength;
		}
	}

	void push(E el)
	{
		reserve(1);
		m_storage[m_fill++] = el;
		debug if (m_fill > m_maxFill) m_maxFill = m_fill;
	}

	void push(E[] els)
	{
		reserve(els.length);
		foreach (el; els)
			m_storage[m_fill++] = el;
		debug if (m_fill > m_maxFill) m_maxFill = m_fill;
	}

	E pop()
	{
		assert(!empty, "Stack underflow.");
		return m_storage[--m_fill];
	}
}
