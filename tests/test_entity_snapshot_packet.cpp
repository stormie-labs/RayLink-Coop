// Anomaly Coop unit tests: the bytes of an EntitySnapshot packet (coop_snapshots.cpp host_send_snapshots).
// The host writes each packet in place: the header (u32 time, u16 count) first, the count patched in when the packet goes.
// The reference below builds the same packets the copying way (the entries apart, the header put in front of a copy of
// them); both must give the same packets, byte for byte, for any run of entries, with the same budget and 255-entry limit.
#include "test_util.h"

#include "coop_wire.h"

#include <algorithm>
#include <cstdint>
#include <fstream>
#include <iterator>
#include <string>
#include <vector>

using namespace coop;

namespace
{
constexpr size_t kBudget = 1100; // coop_snapshots.cpp kSnapshotBudget
constexpr size_t kHeader = 6; // kSnapshotHeader
constexpr size_t kCountAt = 4; // kSnapshotCountAt

using Packets = std::vector<std::vector<uint8_t>>;

// An entry of `size` bytes whose content tells it apart.
Writer entry_of(size_t size, uint32_t serial)
{
	Writer e;
	for (size_t i = 0; i < size; ++i)
		e.u8(uint8_t(serial * 31u + i));
	return e;
}

// The reference: entries gathered apart, each packet a new Writer with the header in front of a copy of them.
Packets copied(const std::vector<Writer>& entries, uint32_t now)
{
	Packets out;
	Writer w(kBudget + 128);
	uint16_t in_packet = 0;
	const auto flush = [&]() {
		if (!in_packet)
			return;
		Writer packet(w.size() + 8);
		packet.u32(now);
		packet.u16(in_packet);
		packet.bytes(w.ptr(), w.size());
		out.push_back(packet.data());
		w.clear();
		in_packet = 0;
	};
	for (const Writer& entry : entries)
	{
		if (in_packet && w.size() + entry.size() > kBudget)
			flush();
		w.bytes(entry.ptr(), entry.size());
		if (++in_packet >= 255 || w.size() >= kBudget)
			flush();
	}
	flush();
	return out;
}

// As host_send_snapshots writes them: one Writer kept across packets, the header written first and its count patched.
Packets in_place(const std::vector<Writer>& entries, uint32_t now, Writer& w)
{
	Packets out;
	const auto start = [&]() {
		w.clear();
		w.u32(now);
		w.u16(0);
	};
	start();
	uint16_t in_packet = 0;
	const auto flush = [&]() {
		if (!in_packet)
			return;
		w.patch_u16(kCountAt, in_packet);
		out.push_back(w.data());
		start();
		in_packet = 0;
	};
	for (const Writer& entry : entries)
	{
		if (in_packet && w.size() - kHeader + entry.size() > kBudget)
			flush();
		w.bytes(entry.ptr(), entry.size());
		if (++in_packet >= 255 || w.size() - kHeader >= kBudget)
			flush();
	}
	flush();
	return out;
}

std::vector<Writer> run_of(uint32_t seed, size_t count, size_t min_size, size_t max_size)
{
	std::vector<Writer> entries;
	uint32_t x = seed;
	for (size_t i = 0; i < count; ++i)
	{
		x = x * 1664525u + 1013904223u;
		entries.push_back(entry_of(min_size + (x >> 8) % (max_size - min_size + 1), uint32_t(i)));
	}
	return entries;
}

std::string project_file(const std::string& rel)
{
	std::string here = __FILE__;
	const size_t slash = here.find_last_of("\\/");
	here.resize(slash == std::string::npos ? 0 : slash);
	std::ifstream f(here + "/../" + rel, std::ios::binary);
	std::string text((std::istreambuf_iterator<char>(f)), std::istreambuf_iterator<char>());
	text.erase(std::remove(text.begin(), text.end(), '\r'), text.end());
	return text;
}

std::string between(const std::string& src, const std::string& from, const std::string& to)
{
	const size_t at = src.find(from);
	if (at == std::string::npos)
		return std::string();
	const size_t end = src.find(to, at + from.size());
	return src.substr(at, end == std::string::npos ? std::string::npos : end - at);
}
} // namespace

TEST(entity_snapshot_packet_in_place_matches_the_copied_header)
{
	Writer kept(kHeader + kBudget + 128);
	struct Run
	{
		uint32_t seed;
		size_t count, min_size, max_size;
	};
	// creatures with and without aim and attachments, a run of small entries that hits the 255 limit, entries over the budget
	for (const Run& r : {Run{1, 0, 20, 20}, Run{2, 1, 20, 20}, Run{3, 40, 20, 140}, Run{4, 300, 20, 30}, Run{5, 600, 3, 6},
	         Run{6, 30, 900, 1400}, Run{7, 200, 1, 400}})
	{
		const std::vector<Writer> entries = run_of(r.seed, r.count, r.min_size, r.max_size);
		const uint32_t now = 0x01020304u + r.seed;
		const Packets want = copied(entries, now);
		const Packets got = in_place(entries, now, kept); // the same Writer from run to run, as across snapshots
		CHECK_EQ(got.size(), want.size());
		for (size_t i = 0; i < got.size() && i < want.size(); ++i)
			CHECK(got[i] == want[i]);
	}
}

TEST(entity_snapshot_packet_count_sits_after_the_time)
{
	Writer w;
	w.u32(0xaabbccddu);
	w.u16(0);
	w.u8(7);
	w.patch_u16(kCountAt, 0x0102);
	const std::vector<uint8_t> want = {0xdd, 0xcc, 0xbb, 0xaa, 0x02, 0x01, 7};
	CHECK(w.data() == want);
}

// The engine writes the packet as in_place above: no per-creature Writer, no copy of the packet at its flush.
TEST(entity_snapshot_packet_engine_writes_in_place)
{
	const std::string src = project_file("engine/src/xrGame/coop/coop_snapshots.cpp");
	REQUIRE(!src.empty());
	CHECK(src.find("constexpr size_t kSnapshotBudget = 1100;") != std::string::npos);
	CHECK(src.find("constexpr size_t kSnapshotHeader = 6;") != std::string::npos);
	CHECK(src.find("constexpr size_t kSnapshotCountAt = 4;") != std::string::npos);
	const std::string send = between(src, "void host_send_snapshots()", "\n}\n");
	REQUIRE(!send.empty());
	CHECK(send.find("Writer out(") == std::string::npos);
	CHECK(send.find("Writer entry(") == std::string::npos);
	CHECK(send.find("w.u32(u32(now));\n\t\tw.u16(0);") != std::string::npos);
	CHECK(send.find("w.patch_u16(kSnapshotCountAt, in_packet);") != std::string::npos);
	CHECK(send.find("net::host_broadcast(Msg::EntitySnapshot, w, Lane::Unreliable);") != std::string::npos);
	CHECK(send.find("entry.clear();") != std::string::npos);
	CHECK(send.find("if (in_packet && w.size() - kSnapshotHeader + entry.size() > kSnapshotBudget) flush();") != std::string::npos);
	CHECK(send.find("if (++in_packet >= 255 || w.size() - kSnapshotHeader >= kSnapshotBudget)") != std::string::npos);
}
