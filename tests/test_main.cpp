// Anomaly Coop unit tests: runner and shared helpers.
// Usage: coop_tests.exe [name-substring ...]   (no argument = run everything)
#include "test_util.h"

#include <cstring>
#include <exception>

namespace t
{
std::vector<TestCase>& registry()
{
	static std::vector<TestCase> tests;
	return tests;
}

int& failures_in_test()
{
	static int n = 0;
	return n;
}

void report_failure(const char* file, int line, const std::string& what)
{
	++failures_in_test();
	std::printf("    FAILED %s:%d: %s\n", file, line, what.c_str());
	std::fflush(stdout);
}

coop::Manifest sample_manifest()
{
	return {
		{"gamedata\\configs\\system.ltx", 0x1111111111111111ull},
		{"gamedata\\scripts\\bind_stalker.script", 0x2222222222222222ull},
		{"gamedata\\meshes\\actors\\stalker_hero.ogf", 0x3333333333333333ull},
	};
}

std::vector<uint8_t> random_bytes(size_t size, uint64_t seed)
{
	std::vector<uint8_t> v(size);
	uint64_t s = seed ? seed : 1;
	for (size_t i = 0; i < size; ++i)
	{
		s ^= s << 13;
		s ^= s >> 7;
		s ^= s << 17;
		v[i] = uint8_t(s >> 24);
	}
	return v;
}

Node::Node(const std::string& nick, uint16_t port)
{
	cfg.port = port;
	cfg.build_id = "test-build-1";
	cfg.manifest = sample_manifest();
	cfg.key = coop::generate_player_key();
	cfg.nick = nick;
	cfg.connect_timeout_ms = 5000;
	cfg.peer_timeout_ms = 15000;

	s.set_log([this](const char* line) { log.emplace_back(line); });
	s.on_peer_joined = [this](const coop::PeerInfo& p) { joined.push_back(p); };
	s.on_peer_left = [this](coop::PeerId id, const std::string& reason) { left.emplace_back(id, reason); };
	s.on_welcome = [this](const coop::WelcomeMsg& w) {
		welcomed = true;
		welcome = w;
	};
	s.on_rejected = [this](const coop::RejectMsg& r, const coop::ManifestDiff& d) {
		rejected = true;
		reject = r;
		diff = d;
	};
	s.on_disconnected = [this](const std::string& reason) {
		disconnected = true;
		disc_reason = reason;
		disc_at = now_ms();
	};
	s.on_chat = [this](coop::PeerId from, const std::string& text) { chat.emplace_back(from, text); };
	s.on_blob_progress = [this](coop::PeerId from, uint32_t id, uint32_t kind, uint64_t done, uint64_t total) {
		progress.push_back({from, id, kind, done, total});
	};
	s.on_blob_complete = [this](coop::PeerId from, uint32_t id, uint32_t kind, std::vector<uint8_t>& data) {
		blobs.push_back({from, id, kind, std::move(data)});
	};
}

bool Node::logged(const std::string& needle) const
{
	for (const std::string& l : log)
		if (l.find(needle) != std::string::npos)
			return true;
	return false;
}
} // namespace t

int main(int argc, char** argv)
{
	std::setvbuf(stdout, nullptr, _IONBF, 0);
	std::vector<t::TestCase> selected;
	for (const t::TestCase& tc : t::registry())
	{
		bool take = argc <= 1;
		for (int i = 1; i < argc; ++i)
			if (std::strstr(tc.name, argv[i]))
				take = true;
		if (take)
			selected.push_back(tc);
	}

	int failed = 0;
	const uint64_t t0 = t::now_ms();
	for (const t::TestCase& tc : selected)
	{
		t::failures_in_test() = 0;
		std::printf("[ RUN  ] %s\n", tc.name);
		const uint64_t start = t::now_ms();
		try
		{
			tc.fn();
		}
		catch (const t::Abort&)
		{
		}
		catch (const std::exception& e)
		{
			t::report_failure(__FILE__, __LINE__, std::string("unexpected exception: ") + e.what());
		}
		catch (...)
		{
			t::report_failure(__FILE__, __LINE__, "unexpected unknown exception");
		}
		const bool ok = t::failures_in_test() == 0;
		if (!ok)
			++failed;
		std::printf("[ %s ] %s (%llu ms)\n", ok ? " OK " : "FAIL", tc.name,
			static_cast<unsigned long long>(t::now_ms() - start));
	}

	std::printf("\n%zu tests, %d passed, %d failed (%llu ms)\n", selected.size(), int(selected.size()) - failed,
		failed, static_cast<unsigned long long>(t::now_ms() - t0));
	return failed ? 1 : 0;
}
