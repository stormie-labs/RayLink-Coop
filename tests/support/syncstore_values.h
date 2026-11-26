// Anomaly Coop unit tests: the values the tests build that the engine never makes in C++ (a nil, a table); the engine takes
// them from Lua (coop_syncstore.h Value).
#pragma once

#include <string>
#include <utility>
#include <vector>

#include "coop_syncstore.h"

namespace coop
{
namespace syncstore
{
inline Value make_nil() { return Value(); }

inline Value make_table(std::vector<std::pair<std::string, Value>> fields)
{
	Value r;
	r.type = ValueType::Table;
	r.table = std::move(fields);
	return r;
}
} // namespace syncstore
} // namespace coop
