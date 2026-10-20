// Anomaly Coop unit tests: tiny test framework and shared helpers (no external dependencies).
#pragma once

#include <chrono>
#include <cstdint>
#include <cstdio>
#include <functional>
#include <initializer_list>
#include <sstream>
#include <string>
#include <thread>
#include <type_traits>
#include <utility>
#include <vector>

#include "coop_protocol.h"
#include "coop_session.h"
#include "coop_wire.h"

namespace t
{
struct Abort
{
};

struct TestCase
{
	const char* name;
	void (*fn)();
};

std::vector<TestCase>& registry();
int& failures_in_test();
void report_failure(const char* file, int line, const std::string& what);

struct Registrar
{
	Registrar(const char* name, void (*fn)()) { registry().push_back({name, fn}); }
};

template <class T>
std::string str(const T& v)
{
	if constexpr (std::is_enum_v<T>)
		return std::to_string(static_cast<long long>(v));
	else if constexpr (std::is_arithmetic_v<T>)
	{
		std::ostringstream o;
		o << +v;
		return o.str();
	}
	else if constexpr (std::is_convertible_v<T, std::string>)
		return "\"" + std::string(v) + "\"";
	else
		return "?";
}

inline uint64_t now_ms()
{
	using namespace std::chrono;
	return uint64_t(duration_cast<milliseconds>(steady_clock::now().time_since_epoch()).count());
}

// Updates every session in a loop until pred() is true or the deadline passes. Returns pred().
template <class Pred>
bool pump_until(std::initializer_list<coop::Session*> sessions, uint32_t timeout_ms, Pred pred, bool sleep = true)
{
	const uint64_t start = now_ms();
	for (;;)
	{
		const uint64_t now = now_ms();
		for (coop::Session* s : sessions)
			s->update(now);
		if (pred())
			return true;
		if (now - start > timeout_ms)
			return false;
		if (sleep)
			std::this_thread::sleep_for(std::chrono::milliseconds(1));
		else
			std::this_thread::yield();
	}
}

inline void pump_for(std::initializer_list<coop::Session*> sessions, uint32_t ms)
{
	const uint64_t start = now_ms();
	pump_until(sessions, ms, [&] { return now_ms() - start >= ms; });
}

coop::Manifest sample_manifest();

// A session plus a recorder of everything its callbacks report.
struct Node
{
	struct BlobProgress
	{
		coop::PeerId from;
		uint32_t id, kind;
		uint64_t done, total;
	};
	struct BlobDone
	{
		coop::PeerId from;
		uint32_t id, kind;
		std::vector<uint8_t> data;
	};

	Node(const std::string& nick, uint16_t port);

	coop::Session s;
	coop::SessionConfig cfg;
	std::vector<std::string> log;
	std::vector<coop::PeerInfo> joined;
	std::vector<std::pair<coop::PeerId, std::string>> left;
	bool welcomed = false;
	coop::WelcomeMsg welcome;
	bool rejected = false;
	coop::RejectMsg reject;
	coop::ManifestDiff diff;
	bool disconnected = false;
	std::string disc_reason;
	uint64_t disc_at = 0;
	std::vector<std::pair<coop::PeerId, std::string>> chat;
	std::vector<BlobProgress> progress;
	std::vector<BlobDone> blobs;

	bool host(std::string* err = nullptr) { return s.host(cfg, err); }
	bool connect(uint16_t port, std::string* err = nullptr) { return s.connect(cfg, "127.0.0.1", port, err); }
	bool logged(const std::string& needle) const;
};

std::vector<uint8_t> random_bytes(size_t size, uint64_t seed);
} // namespace t

#define TEST(name)                                       \
	static void name();                                  \
	static ::t::Registrar t_reg_##name(#name, &name);    \
	static void name()

#define CHECK(cond)                                                       \
	do                                                                    \
	{                                                                     \
		if (!(cond))                                                      \
			::t::report_failure(__FILE__, __LINE__, "CHECK(" #cond ")");  \
	} while (0)

#define REQUIRE(cond)                                                       \
	do                                                                      \
	{                                                                       \
		if (!(cond))                                                        \
		{                                                                   \
			::t::report_failure(__FILE__, __LINE__, "REQUIRE(" #cond ")");  \
			throw ::t::Abort();                                             \
		}                                                                   \
	} while (0)

#define CHECK_EQ(a, b)                                                                                     \
	do                                                                                                     \
	{                                                                                                      \
		const auto t_a = (a);                                                                              \
		const auto t_b = (b);                                                                              \
		if (!(t_a == t_b))                                                                                 \
			::t::report_failure(__FILE__, __LINE__,                                                        \
				"CHECK_EQ(" #a ", " #b "): " + ::t::str(t_a) + " != " + ::t::str(t_b));                    \
	} while (0)
