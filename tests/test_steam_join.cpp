// Anomaly Coop unit tests: the tunnel address the launcher leaves for a running game (coop_steam_join.h).
#include "test_util.h"

#include "coop_steam_join.h"

using coop::steam_join::parse_tunnel;

TEST(steam_join_takes_a_loopback_port)
{
	uint16_t port = 0;
	CHECK(parse_tunnel("127.0.0.1:51234", port));
	CHECK_EQ(port, 51234u);
	CHECK(parse_tunnel("127.0.0.1:27960\r\n", port));
	CHECK_EQ(port, 27960u);
	CHECK(parse_tunnel("127.0.0.1:65535", port));
	CHECK_EQ(port, 65535u);
}

TEST(steam_join_refuses_anything_else)
{
	uint16_t port = 7;
	CHECK(!parse_tunnel(nullptr, port));
	CHECK(!parse_tunnel("", port));
	CHECK(!parse_tunnel("127.0.0.1", port));
	CHECK(!parse_tunnel("127.0.0.1:", port));
	CHECK(!parse_tunnel("127.0.0.1:0", port));
	CHECK(!parse_tunnel("127.0.0.1:65536", port));
	CHECK(!parse_tunnel("127.0.0.1:1234567", port));
	CHECK(!parse_tunnel("127.0.0.1:27960 -coop_host", port));
	CHECK(!parse_tunnel("10.0.0.5:27960", port));
	CHECK(!parse_tunnel("127.0.0.11:27960", port));
	CHECK_EQ(port, 7u);
}
