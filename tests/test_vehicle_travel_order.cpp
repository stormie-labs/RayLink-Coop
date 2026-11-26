// F5-VEH-6 (rv_F5-VEH-6 blocker 2, INTEG-C): a player's machine leaves its world only after its own actor is out of a managed
// seat. Co-op: the save of a group transition waits for the local detach (the host released every seat before LoadWait Prepared,
// and the release and the save can both come before the frame that detaches him). Server: his ask to leave his level waits for the
// release of the map server of this level and the local detach (the world server would move him to another map at once).
// The rule is transition::SeatHold (xrCoop/coop_transition.h); the engine's wiring is read from coop_join.cpp (the native target does
// not link xrGame).
#include "test_util.h"
#include "coop_transition.h"

#include <fstream>
#include <iterator>
#include <string>
#include <string_view>

namespace
{
using coop::transition::kSeatDetachHoldMs;
using coop::transition::SeatHold;
using coop::transition::TravelStep;

std::string join_source()
{
	const std::string here = __FILE__;
	const auto slash = here.find_last_of("\\/");
	const auto dir = slash == std::string::npos ? std::string(".") : here.substr(0, slash);
	std::string all; // the join module: coop_join.cpp and the files it is split into
	for (const char* file : {"coop_join.cpp", "coop_join_characters.cpp", "coop_join_transition.cpp", "coop_join_transition_load.cpp", "coop_join_swap.cpp"})
	{
		std::ifstream in(dir + "/../engine/src/xrGame/coop/" + file, std::ios::binary);
		all.append(std::istreambuf_iterator<char>(in), {});
	}
	return all;
}

std::string_view section(std::string_view source, std::string_view start, std::string_view end)
{
	const size_t first = source.find(start);
	REQUIRE(first != std::string_view::npos);
	const size_t last = source.find(end, first + start.size());
	REQUIRE(last != std::string_view::npos);
	return source.substr(first, last - first);
}

size_t at(std::string_view code, std::string_view what)
{
	const size_t p = code.find(what);
	CHECK(p != std::string_view::npos);
	return p;
}
} // namespace

TEST(seat_hold_goes_at_once_when_nobody_sits)
{
	SeatHold h;
	CHECK_EQ(h.step(false, 100), TravelStep::Go);
	CHECK(!h.active());
}

TEST(seat_hold_waits_while_seated_and_goes_after_the_detach)
{
	SeatHold h;
	CHECK_EQ(h.step(true, 1000), TravelStep::Wait);
	CHECK(h.active());
	CHECK_EQ(h.step(true, 1000 + kSeatDetachHoldMs - 1), TravelStep::Wait);
	CHECK_EQ(h.step(false, 1000 + kSeatDetachHoldMs - 1), TravelStep::Go); // the detach ran: the travel goes
	CHECK(!h.active());
	// a later travel starts its own clock
	CHECK_EQ(h.step(true, 50000), TravelStep::Wait);
}

TEST(seat_hold_lets_a_stuck_exit_go_late)
{
	SeatHold h;
	CHECK_EQ(h.step(true, 0), TravelStep::Wait); // the clock starts at 0 too
	CHECK_EQ(h.step(true, kSeatDetachHoldMs), TravelStep::GoLate);
	CHECK(!h.active());
	CHECK_EQ(h.step(true, kSeatDetachHoldMs + 1), TravelStep::Wait); // a new hold, a new clock
	h.clear();
	CHECK(!h.active());
}

// Co-op: the normal detach runs before the scripts keep their per-player state and before the world is replaced; the save of the
// transition is held while the actor still sits.
TEST(seat_hold_coop_prepared_detaches_before_the_world_goes)
{
	const std::string src = join_source();
	REQUIRE(!src.empty());
	const auto prepared = section(src, "void client_prepared(const levels::wire::LoadWaitMsg& m, u64 now)", "\n}");
	const size_t steps = at(prepared, "client_seat_steps_now()");
	const size_t leaving = at(prepared, "world_leaving(m.epoch)");
	const size_t reset = at(prepared, "sync::reset()");
	CHECK(steps < leaving);
	CHECK(leaving < reset);
	const auto steps_fn = section(src, "void client_seat_steps_now()", "\n}");
	at(steps_fn, "vehicles::local_seat_attached()");
	at(steps_fn, "vehicles::client_frame()");
	at(steps_fn, "vehicles::ride_frame()");

	const auto blob = section(src, "void on_blob_complete(PeerId from", "\n}");
	const auto prepared_part = section(blob, "if (kind == BlobPreparedSave)", "if (kind != BlobWorldSave)");
	const size_t hold = at(prepared_part, "g_load.save_hold.step(vehicles::local_seat_attached(), mgr().now_ms())");
	const size_t load = at(prepared_part, "client_load_world(data)");
	CHECK(hold < load);
	at(prepared_part, "g_load.seated_save.swap(data)");

	const auto holds = section(src, "void client_seat_holds(u64 now)", "\n}");
	at(holds, "g_load.save_hold.step(vehicles::local_seat_attached(), now)");
	at(holds, "client_load_world(save)");
	at(holds, "prepared_save_awaited()");
	const auto frame = section(src, "void frame()", "\n}");
	at(frame, "client_seat_holds(mgr().now_ms())");
}

// Server: the LevelMove of an exit and of a trip goes through the hold; the actor is asked out first.
TEST(seat_hold_server_move_waits_for_the_release_and_detach)
{
	const std::string src = join_source();
	REQUIRE(!src.empty());
	const auto exit_move = section(src, "void client_level_move(u16 changer, u64 now)\r\n{", "\n}");
	at(exit_move, "client_send_move(m, now)");
	at(exit_move, "g_load.move_held");
	CHECK(exit_move.find("net::client_send(Msg::LevelMove") == std::string_view::npos);
	const auto trip = section(src, "void client_level_trip(NET_Packet& P)", "\n}");
	at(trip, "client_send_move(m, now)");
	at(trip, "g_load.move_held");
	CHECK(trip.find("net::client_send(Msg::LevelMove") == std::string_view::npos);

	const auto send = section(src, "bool client_send_move(const levels::wire::LevelMoveMsg& m, u64 now)", "\n}");
	const size_t hold = at(send, "g_load.move_hold.step(vehicles::local_seat_attached(), now)");
	const size_t out = at(send, "\"exit_for_travel\"");
	const size_t sent = at(send, "move_out(m, now)");
	CHECK(hold < out);
	CHECK(out < sent);
	const auto holds = section(src, "void client_seat_holds(u64 now)", "\n}");
	at(holds, "g_load.move_hold.step(vehicles::local_seat_attached(), now)");
	at(holds, "move_out(g_load.held_move, now)");
	const auto move_out = section(src, "void move_out(const levels::wire::LevelMoveMsg& m, u64 now)", "\n}");
	at(move_out, "net::client_send(Msg::LevelMove, w)");
}
