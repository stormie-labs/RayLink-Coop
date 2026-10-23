// Anomaly Coop unit tests: the handler tables of the game modules (F3a T4, fix round 1 item 2).
//
// Every coop module registers its game message handlers in two tables (engine/src/xrGame/coop/*.cpp):
// install_server(Session&) for the world server, on the hosting session, and install_client(Endpoint&) for a client, on a
// remote client's session or on the host player's LocalLink. A hosting session takes only ClientOnly and Either messages,
// a client's session only HostOnly and Either ones (Session game_message refuses the rest before any handler; TrunkOnly
// from everybody until F3a T9). So:
//   - the server tables hold ClientOnly and Either types only, the client tables HostOnly and Either types only;
//   - an Either type is in both: in one only, the other side drops it (no handler) where it used to run;
//   - a type is registered by one module only per side (one handler per type, the last would win silently);
//   - a file that defines one table defines the other.
// The test reads the sources: every Msg::X inside the body of a function named ...install_server / ...install_client
// counts as a registration of X there (keep handler logic in named functions, out of the bodies). F3a T7 edits these
// tables by hand when it moves modules onto the link: this test keeps the split honest.
#include "test_util.h"
#include "coop_protocol.h"

#include <cstring>
#include <filesystem>
#include <fstream>
#include <map>
#include <set>
#include <sstream>
#include <string>
#include <vector>

using namespace coop;

namespace
{
// engine/src/xrGame/coop, found next to this source file (tests\ -> ..\engine\src\xrGame\coop)
std::string coop_dir()
{
	std::string here = __FILE__;
	const size_t slash = here.find_last_of("\\/");
	if (slash == std::string::npos)
		return "engine/src/xrGame/coop";
	here.resize(slash);
	return here + "/../engine/src/xrGame/coop";
}

// The source with // and /* */ comments blanked (string and character literals kept as they are).
std::string strip_comments(const std::string& src)
{
	std::string out = src;
	enum class St
	{
		Code,
		Line,
		Block,
		Str,
		Chr
	} st = St::Code;
	for (size_t i = 0; i < out.size(); ++i)
	{
		const char c = out[i];
		const char n = i + 1 < out.size() ? out[i + 1] : '\0';
		switch (st)
		{
		case St::Code:
			if (c == '/' && n == '/')
			{
				st = St::Line;
				out[i] = ' ';
			}
			else if (c == '/' && n == '*')
			{
				st = St::Block;
				out[i] = ' ';
				out[++i] = ' ';
			}
			else if (c == '"')
				st = St::Str;
			else if (c == '\'')
				st = St::Chr;
			break;
		case St::Line:
			if (c == '\n')
				st = St::Code;
			else
				out[i] = ' ';
			break;
		case St::Block:
			if (c == '*' && n == '/')
			{
				out[i] = ' ';
				out[++i] = ' ';
				st = St::Code;
			}
			else if (c != '\n')
				out[i] = ' ';
			break;
		case St::Str:
		case St::Chr:
			if (c == '\\')
				++i;
			else if (c == (st == St::Str ? '"' : '\''))
				st = St::Code;
			break;
		}
	}
	return out;
}

bool ident_char(char c)
{
	return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_';
}

bool ends_with(const std::string& s, const char* tail)
{
	const size_t n = std::strlen(tail);
	return s.size() >= n && s.compare(s.size() - n, n, tail) == 0;
}

// Every game message by its name in msg_name.
const std::map<std::string, uint16_t>& msg_by_name()
{
	static const std::map<std::string, uint16_t> table = [] {
		std::map<std::string, uint16_t> m;
		for (uint32_t v = uint32_t(Msg::GameBase); v <= 0xFFFFu; ++v)
		{
			const char* name = msg_name(static_cast<Msg>(uint16_t(v)));
			if (std::strncmp(name, "Msg_0x", 6) != 0)
				m.emplace(name, uint16_t(v));
		}
		return m;
	}();
	return table;
}

// One install function found in a source.
struct Table
{
	std::string file;
	std::string function; // e.g. "install_server", "equip_install_client"
	bool server = false;
	std::set<uint16_t> types;
};

// The install_server / install_client definitions of one source text (comments stripped first). Unknown Msg:: names go
// to `problems`.
std::vector<Table> parse_tables(const std::string& file, const std::string& source, std::vector<std::string>& problems)
{
	const std::string src = strip_comments(source);
	std::vector<Table> out;
	size_t pos = 0;
	while ((pos = src.find("void ", pos)) != std::string::npos)
	{
		const bool line_start = pos == 0 || src[pos - 1] == '\n';
		size_t i = pos + 5;
		pos = i;
		if (!line_start)
			continue;
		while (i < src.size() && (src[i] == ' ' || src[i] == '\t'))
			++i;
		size_t name_end = i;
		while (name_end < src.size() && ident_char(src[name_end]))
			++name_end;
		const std::string name = src.substr(i, name_end - i);
		const bool server = ends_with(name, "install_server");
		if (!server && !ends_with(name, "install_client"))
			continue;
		size_t j = name_end;
		while (j < src.size() && src[j] != '(')
			++j;
		int depth = 0;
		for (; j < src.size(); ++j)
		{
			if (src[j] == '(')
				++depth;
			else if (src[j] == ')' && --depth == 0)
				break;
		}
		++j;
		while (j < src.size() && (src[j] == ' ' || src[j] == '\t' || src[j] == '\r' || src[j] == '\n'))
			++j;
		if (j >= src.size() || src[j] != '{')
			continue; // a declaration
		const size_t open = j;
		depth = 0;
		for (; j < src.size(); ++j)
		{
			if (src[j] == '{')
				++depth;
			else if (src[j] == '}' && --depth == 0)
				break;
		}
		const std::string body = src.substr(open, j - open);
		Table t;
		t.file = file;
		t.function = name;
		t.server = server;
		size_t m = 0;
		while ((m = body.find("Msg::", m)) != std::string::npos)
		{
			m += 5;
			size_t e = m;
			while (e < body.size() && ident_char(body[e]))
				++e;
			const std::string type = body.substr(m, e - m);
			const auto it = msg_by_name().find(type);
			if (it == msg_by_name().end())
				problems.push_back(file + " " + name + ": Msg::" + type + " is no game message");
			else
				t.types.insert(it->second);
			m = e;
		}
		out.push_back(std::move(t));
		pos = j;
	}
	return out;
}

const char* sender_name(MsgSender s)
{
	switch (s)
	{
	case MsgSender::Either: return "Either";
	case MsgSender::HostOnly: return "HostOnly";
	case MsgSender::ClientOnly: return "ClientOnly";
	case MsgSender::TrunkOnly: return "TrunkOnly";
	}
	return "?";
}

// The rules of the header above over the tables found. Empty: the split is honest.
std::vector<std::string> table_problems(const std::vector<Table>& tables)
{
	std::vector<std::string> problems;
	std::map<uint16_t, std::vector<std::string>> by_side[2]; // [server?1:0][type] -> where
	std::map<std::string, std::set<std::string>> pairs; // file -> table names, prefix + side
	for (const Table& t : tables)
	{
		pairs[t.file].insert(t.function);
		for (uint16_t type : t.types)
		{
			by_side[t.server ? 1 : 0][type].push_back(t.file + " " + t.function);
			const MsgSender s = msg_sender(static_cast<Msg>(type));
			const bool fits = t.server ? (s == MsgSender::ClientOnly || s == MsgSender::Either)
			                           : (s == MsgSender::HostOnly || s == MsgSender::Either);
			if (!fits)
				problems.push_back(std::string(msg_name(type)) + " (" + sender_name(s) + ") in " + t.file + " " +
					t.function + ": " + (t.server ? "a hosting session never takes it" : "a client's session never takes it"));
		}
	}
	for (int side = 0; side < 2; ++side)
		for (const auto& kv : by_side[side])
		{
			if (kv.second.size() > 1)
			{
				std::string where;
				for (const std::string& w : kv.second)
					where += " [" + w + "]";
				problems.push_back(std::string(msg_name(kv.first)) + " registered twice in the " +
					(side ? "server" : "client") + " tables:" + where);
			}
			if (msg_sender(static_cast<Msg>(kv.first)) == MsgSender::Either && !by_side[1 - side].count(kv.first))
				problems.push_back(std::string(msg_name(kv.first)) + " (Either) only in the " + (side ? "server" : "client") +
					" tables (" + kv.second.front() + "): the other side takes it too and would drop it");
		}
	for (const auto& kv : pairs)
		for (const std::string& f : kv.second)
		{
			const bool server = ends_with(f, "install_server");
			const std::string other = f.substr(0, f.size() - 6) + (server ? "client" : "server");
			if (!kv.second.count(other))
				problems.push_back(kv.first + " defines " + f + " without " + other);
		}
	return problems;
}

std::vector<Table> tables_of(const std::string& source, std::vector<std::string>& problems)
{
	return parse_tables("test.cpp", source, problems);
}

void expect_problem(const std::vector<std::string>& problems, const std::string& needle)
{
	for (const std::string& p : problems)
		if (p.find(needle) != std::string::npos)
			return;
	std::string all;
	for (const std::string& p : problems)
		all += "\n      " + p;
	::t::report_failure(__FILE__, __LINE__, "no problem mentions '" + needle + "'; problems:" + all);
}
} // namespace

// The checker itself: comments, one-line and multi-line bodies, declarations; and each rule catches its mistake.
TEST(handler_tables_checker_catches_mistakes)
{
	std::vector<std::string> parse;
	const std::string clean = "void install_server(Session& s); // a declaration: Msg::WorldBlob\n"
							  "void install_server(Session& s) { s.on(Msg::ReqSpawn, &a); s.on(Msg::PlayerState, &b); }\n"
							  "\n"
							  "void install_client(Endpoint& e)\n"
							  "{\n"
							  "\te.on(Msg::TimeSync, &c); /* Msg::ReqHit */ // Msg::JoinRequest\n"
							  "\te.on(Msg::PlayerState, &b);\n"
							  "}\n";
	const std::vector<Table> t = tables_of(clean, parse);
	CHECK(parse.empty());
	REQUIRE(t.size() == 2);
	CHECK(t[0].server && t[0].types == (std::set<uint16_t>{uint16_t(Msg::ReqSpawn), uint16_t(Msg::PlayerState)}));
	CHECK(!t[1].server && t[1].types == (std::set<uint16_t>{uint16_t(Msg::TimeSync), uint16_t(Msg::PlayerState)}));
	CHECK(table_problems(t).empty());

	// an Either type in the client table only
	std::vector<Table> m = tables_of("void install_server(Session& s) { s.on(Msg::ReqSpawn, &a); }\n"
									 "void install_client(Endpoint& e) { e.on(Msg::PlayerState, &b); }\n",
		parse);
	expect_problem(table_problems(m), "PlayerState (Either) only in the client tables");
	// a ClientOnly type in a client table, a HostOnly one in a server table, a TrunkOnly one anywhere
	m = tables_of("void install_server(Session& s) { s.on(Msg::TimeSync, &a); s.on(Msg::LevelSnapshot, &c); }\n"
				  "void install_client(Endpoint& e) { e.on(Msg::ReqSpawn, &b); }\n",
		parse);
	const std::vector<std::string> p = table_problems(m);
	expect_problem(p, "ReqSpawn (ClientOnly) in test.cpp install_client");
	expect_problem(p, "TimeSync (HostOnly) in test.cpp install_server");
	expect_problem(p, "LevelSnapshot (TrunkOnly) in test.cpp install_server");
	// a type registered by two modules on one side, a table without its pair, a name that is no message
	m = tables_of("void install_server(Session& s) { s.on(Msg::ReqSpawn, &a); }\n"
				  "void install_client(Endpoint& e) {}\n"
				  "void equip_install_server(Session& s) { s.on(Msg::ReqSpawn, &b); s.on(Msg::NoSuchThing, &c); }\n",
		parse);
	expect_problem(table_problems(m), "ReqSpawn registered twice in the server tables");
	expect_problem(table_problems(m), "defines equip_install_server without equip_install_client");
	expect_problem(parse, "Msg::NoSuchThing is no game message");
}

// The real tables of the game modules.
TEST(handler_tables_split_by_sender)
{
	namespace fs = std::filesystem;
	std::vector<Table> tables;
	std::vector<std::string> problems;
	size_t files = 0;
	std::error_code ec;
	for (const fs::directory_entry& entry : fs::directory_iterator(coop_dir(), ec))
	{
		if (!entry.is_regular_file() || entry.path().extension() != ".cpp")
			continue;
		std::ifstream in(entry.path(), std::ios::binary);
		std::stringstream ss;
		ss << in.rdbuf();
		std::vector<Table> found = parse_tables(entry.path().filename().string(), ss.str(), problems);
		if (!found.empty())
			++files;
		tables.insert(tables.end(), found.begin(), found.end());
	}
	REQUIRE(!ec);
	std::set<uint16_t> types;
	for (const Table& t : tables)
		types.insert(t.types.begin(), t.types.end());
	// the scan sees the modules (25 files, 74 types on 2026-10-24): a broken scan is no pass
	CHECK(files >= 25);
	CHECK(types.size() >= 74);
	const std::vector<std::string> rules = table_problems(tables);
	problems.insert(problems.end(), rules.begin(), rules.end());
	for (const std::string& p : problems)
		::t::report_failure(__FILE__, __LINE__, p);
}
