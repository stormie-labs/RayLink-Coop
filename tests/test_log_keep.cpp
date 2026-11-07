// Anomaly Coop unit tests: the game log of the last runs is kept (xrCoop/coop_log_keep.h, used by xrCore log.cpp).
// Live 2026-11-07: "2 of my 3 artefacts vanished" and "handler error" reports came after a new launch had overwritten
// xray_<nick>.log; the old log now goes to logs\old\<name>_<yyyy-mm-dd_hh-mm-ss of its last write>.log, the newest 10 stay.
#include "test_util.h"

#include "coop_log_keep.h"

#include <set>
#include <string>
#include <vector>

using namespace coop;

namespace
{
const log_keep::Stamp kWhen{2026, 11, 7, 21, 5, 9};
}

TEST(log_keep_stem_and_folder_of_the_log_path)
{
	CHECK_EQ(log_keep::stem_of("C:\\Users\\a\\AppData\\Roaming\\RayLink\\profiles\\bob\\gamma\\logs\\xray_bob.log"),
	    std::string("xray_bob"));
	CHECK_EQ(log_keep::stem_of("xray_bob.LOG"), std::string("xray_bob"));
	CHECK_EQ(log_keep::stem_of("D:/x/logs/xray_bob.log"), std::string("xray_bob"));
	CHECK_EQ(log_keep::stem_of("C:\\logs\\xray_bob.txt"), std::string("")); // not a .log: nothing is moved
	CHECK_EQ(log_keep::stem_of("C:\\logs\\.log"), std::string(""));
	CHECK_EQ(log_keep::folder_of("C:\\a\\logs\\xray_bob.log"), std::string("C:\\a\\logs\\"));
	CHECK_EQ(log_keep::folder_of("D:/x/logs/xray_bob.log"), std::string("D:/x/logs/"));
	CHECK_EQ(log_keep::folder_of("xray_bob.log"), std::string(""));
}

TEST(log_keep_archive_name_carries_the_time_of_the_last_write)
{
	CHECK_EQ(log_keep::archive_name("xray_bob", kWhen), std::string("xray_bob_2026-11-07_21-05-09.log"));
	CHECK_EQ(log_keep::archive_name("xray_bob", kWhen, 2), std::string("xray_bob_2026-11-07_21-05-09_2.log"));
	CHECK_EQ(log_keep::archive_name("xray_bob", kWhen, 1), log_keep::archive_name("xray_bob", kWhen));
}

TEST(log_keep_free_name_never_overwrites_a_kept_log)
{
	std::set<std::string> there;
	auto exists = [&](const std::string& n) { return there.count(n) != 0; };
	CHECK_EQ(log_keep::free_name("xray_bob", kWhen, exists), std::string("xray_bob_2026-11-07_21-05-09.log"));
	there.insert("xray_bob_2026-11-07_21-05-09.log"); // two launches in the same second
	CHECK_EQ(log_keep::free_name("xray_bob", kWhen, exists), std::string("xray_bob_2026-11-07_21-05-09_2.log"));
	for (unsigned n = 2; n <= 9; ++n)
		there.insert(log_keep::archive_name("xray_bob", kWhen, n));
	CHECK_EQ(log_keep::free_name("xray_bob", kWhen, exists), std::string("")); // all taken: the log is not moved
}

TEST(log_keep_an_empty_log_is_not_kept)
{
	CHECK(!log_keep::worth_keeping(0));
	CHECK(log_keep::worth_keeping(1));
}

TEST(log_keep_only_archives_of_this_log_are_recognised)
{
	CHECK(log_keep::is_archive_of("xray_bob_2026-11-07_21-05-09.log", "xray_bob"));
	CHECK(log_keep::is_archive_of("XRAY_BOB_2026-11-07_21-05-09.LOG", "xray_bob")); // Windows names ignore the case
	CHECK(log_keep::is_archive_of("xray_bob_2026-11-07_21-05-09_3.log", "xray_bob"));
	CHECK(!log_keep::is_archive_of("xray_bob.log", "xray_bob"));
	CHECK(!log_keep::is_archive_of("xray_bobby_2026-11-07_21-05-09.log", "xray_bob"));
	CHECK(!log_keep::is_archive_of("xray_bob_2026-11-07_21-05.log", "xray_bob"));
	CHECK(!log_keep::is_archive_of("xray_bob_2026-11-07_21-05-09_x.log", "xray_bob"));
	CHECK(!log_keep::is_archive_of("xray_bob_2026-11-07_21-05-09_1.log", "xray_bob")); // never written by free_name
	CHECK(!log_keep::is_archive_of("xray_bob_2026-11-07_21-05-09.txt", "xray_bob"));
	CHECK(!log_keep::is_archive_of("crash_2026-11-07_21-05-09.log", "xray_bob"));
	CHECK(!log_keep::is_archive_of("xray_bob_2026-11-07_21-05-09.log", ""));
}

TEST(log_keep_prunes_the_oldest_beyond_ten_and_nothing_else)
{
	std::vector<std::string> names;
	for (int day = 1; day <= 12; ++day) // 12 kept logs, listed in no particular order
	{
		const log_keep::Stamp t{2026, 10, day, 12, 0, 0};
		names.push_back(log_keep::archive_name("xray_bob", t));
	}
	std::swap(names[0], names[7]);
	std::swap(names[1], names[11]);
	names.push_back("notes.log"); // not ours
	names.push_back("xray_alice_2026-09-01_10-00-00.log"); // another log's archive
	names.push_back("xray_bob_2026-10-12_12-00-00_2.log"); // the second launch of the newest second
	std::vector<std::string> gone = log_keep::to_prune(names, "xray_bob");
	std::set<std::string> got(gone.begin(), gone.end());
	const std::set<std::string> want{"xray_bob_2026-10-01_12-00-00.log", "xray_bob_2026-10-02_12-00-00.log",
	    "xray_bob_2026-10-03_12-00-00.log"};
	CHECK(got == want);
	CHECK_EQ(gone.size(), size_t(3));
}

TEST(log_keep_nothing_is_pruned_at_ten_or_fewer)
{
	std::vector<std::string> names;
	for (int day = 1; day <= 10; ++day)
		names.push_back(log_keep::archive_name("xray_bob", log_keep::Stamp{2026, 10, day, 0, 0, 0}));
	CHECK(log_keep::to_prune(names, "xray_bob").empty());
	CHECK(log_keep::to_prune(names, "xray_bob", 9).size() == 1);
	CHECK(log_keep::to_prune(names, "xray_bob", 9)[0] == "xray_bob_2026-10-01_00-00-00.log");
	CHECK(log_keep::to_prune({}, "xray_bob").empty());
}

TEST(log_keep_a_newer_second_launch_sorts_after_its_first)
{
	std::vector<std::string> names{"xray_bob_2026-10-01_12-00-00_2.log", "xray_bob_2026-10-01_12-00-00.log",
	    "xray_bob_2026-10-02_12-00-00.log"};
	const std::vector<std::string> gone = log_keep::to_prune(names, "xray_bob", 2);
	CHECK(gone.size() == 1 && gone[0] == "xray_bob_2026-10-01_12-00-00.log");
}
