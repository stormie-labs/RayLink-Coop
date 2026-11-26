// Anomaly Coop unit tests: does a message have a row in the scope table (srv/coop_scope.h scope_row)? The tests ask it to
// find a message of the protocol without a decision.
#pragma once

#include "srv/coop_scope.h"

namespace coop
{
inline bool scope_listed(Msg type)
{
	Scope s = Scope::Core;
	return scope_row(type, s);
}
} // namespace coop
