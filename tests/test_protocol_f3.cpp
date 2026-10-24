// Anomaly Coop unit tests: the F3 messages (checkpoints, shared sleep, death; docs/CHECKPOINTS_DEATH.md) in the
// protocol tables: their wire ids, names for logs and stats, and who may send each one (msg_sender, checked by the
// Session on receipt). Rates of the client-sent ones: test_session_limits.cpp limits_client_rate_rules.
#include "test_util.h"
#include "coop_protocol.h"

#include <string>

using namespace coop;

namespace
{
const char* f3_sender_name(MsgSender s)
{
	switch (s)
	{
	case MsgSender::HostOnly: return "host only";
	case MsgSender::ClientOnly: return "client only";
	case MsgSender::Either: return "either";
	}
	return "?";
}

struct F3Msg
{
	Msg type;
	uint16_t wire;
	const char* name;
	MsgSender sender;
};

// F3 range 0x01C0..0x01CF (F2 has 0x0190..0x019F).
const F3Msg kF3[] = {
	{Msg::CheckpointState, 0x01C0, "CheckpointState", MsgSender::HostOnly}, // the host sets every checkpoint
	{Msg::CheckpointClaim, 0x01C1, "CheckpointClaim", MsgSender::ClientOnly}, // a player reports his tent
	{Msg::RestRequest, 0x01C2, "RestRequest", MsgSender::ClientOnly}, // a player lies down or gets up
	{Msg::RestState, 0x01C3, "RestState", MsgSender::HostOnly}, // who rests, what holds the sleep
	{Msg::RestSleep, 0x01C4, "RestSleep", MsgSender::HostOnly}, // the host skipped the time
	{Msg::DeathMarker, 0x01C5, "DeathMarker", MsgSender::HostOnly}, // where a player's things lie
	{Msg::MonsterEffect, 0x01C7, "MonsterEffect", MsgSender::HostOnly}, // audit A5: a monster ability on a remote player
	{Msg::NewCharacter, 0x01C6, "NewCharacter", MsgSender::ClientOnly}, // hardcore: a dead player starts again
};
} // namespace

TEST(protocol_f3_values)
{
	// The ids are the wire format: append only, never renumber.
	for (const F3Msg& m : kF3)
		CHECK_EQ(std::string(m.name) + " = " + std::to_string(static_cast<uint16_t>(m.type)),
		    std::string(m.name) + " = " + std::to_string(m.wire));
}

TEST(protocol_f3_names)
{
	for (const F3Msg& m : kF3)
		CHECK_EQ(std::string(msg_name(m.type)), std::string(m.name));
}

TEST(protocol_f3_senders)
{
	for (const F3Msg& m : kF3)
		CHECK_EQ(std::string(m.name) + ": " + f3_sender_name(msg_sender(m.type)),
		    std::string(m.name) + ": " + f3_sender_name(m.sender));
}
