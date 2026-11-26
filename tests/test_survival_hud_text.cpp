// Anomaly Coop unit tests: the engine's own HUD lines of the down / dead / reviving player (xrGame/coop/coop_survival.cpp
// build_hud) are shown in the player's language. The native runner cannot link xrGame, so the lines are read in the source:
// every format build_hud hands to xr_sprintf comes from tr_format or holds placeholders only; the reviver's line goes through
// tr_format with its st_coop_* id; that id is in both string tables (text/{eng,rus}/st_coop_survival.xml) with a text that
// death::one_conversion lets through, so the translation, not the English fallback, reaches the screen.
//
// Per mode: build_hud is Core and has no mode branch. The reviver's machine draws the line the same way in Co-op (the host
// player or a client) and in Server (a player on a map server), so this source check holds for both.
#include "test_util.h"

#include "coop_death_rules.h"

#include <cctype>
#include <fstream>
#include <map>
#include <sstream>
#include <string>
#include <vector>

namespace
{
std::string hud_root()
{
	std::string here = __FILE__;
	const size_t slash = here.find_last_of("\\/");
	here.resize(slash == std::string::npos ? 0 : slash);
	return here + "/..";
}

std::string hud_read(const std::string& rel)
{
	std::ifstream in(hud_root() + "/" + rel, std::ios::binary);
	std::ostringstream s;
	s << in.rdbuf();
	return s.str();
}

// The body of a function: from its signature to the first closing brace at the start of a line.
std::string hud_function(const std::string& code, const char* signature)
{
	const size_t start = code.find(signature);
	REQUIRE(start != std::string::npos);
	const size_t end = code.find("\n}", start);
	REQUIRE(end != std::string::npos);
	return code.substr(start, end - start);
}

// A run of characters between tags: every '&' starts one of the entities XML knows.
bool hud_entities_ok(const std::string& chars)
{
	for (size_t at = chars.find('&'); at != std::string::npos; at = chars.find('&', at + 1))
	{
		const size_t semi = chars.find(';', at);
		if (semi == std::string::npos)
			return false;
		const std::string name = chars.substr(at + 1, semi - at - 1);
		const bool numeric = name.size() > 1 && name[0] == '#' &&
		                     name.find_first_not_of("0123456789", 1) == std::string::npos;
		if (!numeric && name != "amp" && name != "lt" && name != "gt" && name != "quot" && name != "apos")
			return false;
	}
	return true;
}

// A string table as the game reads it: the declaration first, one <string_table> root, every tag closed in order, no text
// outside the root, every <string id="..."> once. `ok` is false on any break; `text` maps an id to its <text>.
struct HudTable
{
	bool ok = false;
	std::map<std::string, std::string> text;
};

HudTable hud_parse(const std::string& xml)
{
	HudTable t;
	std::vector<std::string> open;
	std::string id, chars, last_text;
	size_t roots = 0, at = 0;
	for (;;)
	{
		const size_t lt = xml.find('<', at);
		chars = xml.substr(at, (lt == std::string::npos ? xml.size() : lt) - at);
		if (!hud_entities_ok(chars) || (open.empty() && chars.find_first_not_of(" \t\r\n") != std::string::npos))
			return t;
		if (lt == std::string::npos)
			break;
		if (xml.compare(lt, 4, "<!--") == 0)
		{
			const size_t end = xml.find("-->", lt + 4);
			if (end == std::string::npos)
				return t;
			at = end + 3;
			continue;
		}
		const size_t gt = xml.find('>', lt);
		if (gt == std::string::npos)
			return t;
		const std::string tag = xml.substr(lt + 1, gt - lt - 1);
		at = gt + 1;
		if (tag.empty())
			return t;
		if (tag[0] == '?')
		{
			if (lt != 0 || tag.back() != '?')
				return t;
			continue;
		}
		if (tag[0] == '/')
		{
			const std::string name = tag.substr(1);
			if (open.empty() || open.back() != name)
				return t;
			open.pop_back();
			if (name == "text")
				last_text = chars;
			else if (name == "string")
			{
				if (id.empty() || t.text.count(id))
					return t;
				t.text[id] = last_text;
				id.clear();
				last_text.clear();
			}
			continue;
		}
		const std::string name = tag.substr(0, tag.find_first_of(" \t\r\n/"));
		if (open.empty() && (++roots > 1 || name != "string_table"))
			return t;
		if (name == "string")
		{
			const size_t q = tag.find("id=\"");
			if (q == std::string::npos)
				return t;
			const size_t q_end = tag.find('"', q + 4);
			if (q_end == std::string::npos)
				return t;
			id = tag.substr(q + 4, q_end - q - 4);
		}
		if (tag.back() != '/')
			open.push_back(name);
	}
	t.ok = open.empty() && roots == 1;
	return t;
}

// A format argument with no word of its own: only conversions (%s, %u, %%), spaces and punctuation.
bool hud_placeholders_only(const std::string& literal)
{
	for (size_t i = 0; i < literal.size(); ++i)
	{
		if (literal[i] == '%' && i + 1 < literal.size())
		{
			++i;
			continue;
		}
		if (std::isalpha(static_cast<unsigned char>(literal[i])))
			return false;
	}
	return true;
}

constexpr const char* kRevivingId = "st_coop_hud_reviving";
} // namespace

// The parser rejects broken tables, so the real files passing it below are well-formed.
TEST(survival_hud_text_parser_rejects_broken_tables)
{
	const std::string decl = "<?xml version=\"1.0\" encoding=\"windows-1251\"?>\r\n";
	const std::string good = decl + "<string_table>\r\n\t<string id=\"a\">\r\n\t\t<text>A &amp; %s</text>\r\n\t</string>\r\n"
	                                "</string_table>\r\n";
	const HudTable ok = hud_parse(good);
	CHECK(ok.ok);
	CHECK(ok.text.count("a") == 1 && ok.text.at("a") == "A &amp; %s");
	CHECK(!hud_parse(decl + "<string_table><string id=\"a\"><text>A</string></text></string_table>").ok);
	CHECK(!hud_parse(decl + "<string_table><string id=\"a\"><text>A</text></string>").ok);
	CHECK(!hud_parse(decl + "<string_table><string id=\"a\"><text>A & B</text></string></string_table>").ok);
	CHECK(!hud_parse(decl + "<string_table><string id=\"a\"><text>A</text></string><string id=\"a\"><text>B</text>"
	                        "</string></string_table>").ok);
	CHECK(!hud_parse(decl + "<string_table></string_table><string_table></string_table>").ok);
	CHECK(!hud_parse("<string_table>" + decl + "</string_table>").ok);
}

// build_hud: no English sentence reaches xr_sprintf as a format. A format is a tr_format result (the translation that
// passed death::one_conversion, else the English fallback) or placeholders only around tr() texts ("%s %u%%").
TEST(survival_hud_text_formats_come_from_the_string_table)
{
	const std::string hud = hud_function(hud_read("engine/src/xrGame/coop/coop_survival.cpp"), "void build_hud(");
	size_t calls = 0;
	for (size_t at = hud.find("xr_sprintf(buf,"); at != std::string::npos; at = hud.find("xr_sprintf(buf,", at + 1))
	{
		++calls;
		size_t arg = hud.find_first_not_of(" \t\r\n(", at + 15);
		REQUIRE(arg != std::string::npos);
		if (hud.compare(arg, 10, "tr_format(") == 0)
			continue;
		REQUIRE(hud[arg] == '"');
		const size_t close = hud.find('"', arg + 1);
		REQUIRE(close != std::string::npos);
		const std::string literal = hud.substr(arg + 1, close - arg - 1);
		if (!hud_placeholders_only(literal))
			::t::report_failure(__FILE__, __LINE__, "build_hud formats an English literal: \"" + literal + "\"");
	}
	CHECK(calls >= 6);
}

// The reviver's line: its id, an English fallback that passes the same check as the translation, one %s for the nick.
TEST(survival_hud_text_reviving_line_is_translated)
{
	const std::string hud = hud_function(hud_read("engine/src/xrGame/coop/coop_survival.cpp"), "void build_hud(");
	const std::string call = std::string("tr_format(\"") + kRevivingId + "\", \"";
	const size_t at = hud.find(call);
	REQUIRE(at != std::string::npos);
	const size_t start = at + call.size();
	const size_t close = hud.find('"', start);
	REQUIRE(close != std::string::npos);
	const std::string fallback = hud.substr(start, close - start);
	CHECK(coop::death::one_conversion(fallback.c_str(), 's'));
	CHECK(hud.compare(close, 7, "\", 's')") == 0);
	const size_t target = hud.find("g_me.revive_target != 0xffff");
	REQUIRE(target != std::string::npos);
	CHECK(at > target); // the call sits in the reviver's branch
}

// Both string tables: the game's format (cp1251 declaration, CRLF), well-formed, the id once, a text tr_format accepts; the
// Russian text is Cyrillic in cp1251, not UTF-8.
TEST(survival_hud_text_reviving_id_in_both_tables)
{
	for (const char* lang : {"eng", "rus"})
	{
		const std::string xml = hud_read(std::string("gamedata/configs/text/") + lang + "/st_coop_survival.xml");
		REQUIRE(!xml.empty());
		CHECK(xml.rfind("<?xml version=\"1.0\" encoding=\"windows-1251\"?>", 0) == 0);
		std::string lf = xml;
		for (size_t at = lf.find("\r\n"); at != std::string::npos; at = lf.find("\r\n", at))
			lf.erase(at, 2);
		CHECK(lf.find('\n') == std::string::npos);
		const HudTable table = hud_parse(xml);
		CHECK(table.ok);
		const auto it = table.text.find(kRevivingId);
		REQUIRE(it != table.text.end());
		const std::string& text = it->second;
		CHECK(coop::death::one_conversion(text.c_str(), 's'));
		if (std::string(lang) == "rus")
		{
			bool cyrillic = false, utf8 = false;
			for (size_t i = 0; i < text.size(); ++i)
			{
				const unsigned char c = static_cast<unsigned char>(text[i]);
				cyrillic = cyrillic || c >= 0xC0;
				utf8 = utf8 || ((c == 0xD0 || c == 0xD1) && i + 1 < text.size() &&
				                   static_cast<unsigned char>(text[i + 1]) >= 0x80 &&
				                   static_cast<unsigned char>(text[i + 1]) <= 0xBF);
			}
			CHECK(cyrillic);
			CHECK(!utf8);
		}
	}
}
