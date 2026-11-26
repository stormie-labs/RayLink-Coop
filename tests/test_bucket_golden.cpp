// Anomaly Coop unit tests: the token buckets that moved onto xrCoop/coop_bucket.h answer as their old copies did.
// Each Old* below is the code that place had before, kept here as the oracle; the same clock (forward steps, a clock that goes
// back, a long pause, a policy that changes) drives the old and the new one, and every answer and every token count must match.
#include "test_util.h"

#include "coop_bucket.h"
#include "coop_id_lease.h"
#include "coop_ledger.h"
#include "coop_limits.h"
#include "coop_spawn.h"

#include <algorithm>
#include <cstdint>
#include <vector>

using namespace coop;

namespace
{
// The clock: small steps, bursts at one time, a step back, a long pause, more steps.
std::vector<uint64_t> clock_steps()
{
	std::vector<uint64_t> t;
	uint64_t now = 1000;
	uint64_t s = 0x9e3779b97f4a7c15ull;
	for (int i = 0; i < 600; ++i)
	{
		s ^= s << 13;
		s ^= s >> 7;
		s ^= s << 17;
		const uint64_t r = s % 100;
		if (r < 30)
			now += 0; // several at one time
		else if (r < 80)
			now += s % 97;
		else if (r < 90)
			now = now > 500 ? now - (s % 500) : now; // the clock goes back
		else
			now += 5000 + s % 60000; // a pause
		t.push_back(now);
	}
	return t;
}

template <uint32_t Burst, uint32_t IntervalMs> struct OldLeasePacer
{
	bool take(uint64_t now)
	{
		if (!m_started)
		{
			m_started = true;
			m_tokens = double(Burst);
			m_at = now;
		}
		else if (now > m_at)
		{
			m_tokens += double(now - m_at) / double(IntervalMs);
			if (m_tokens > double(Burst))
				m_tokens = double(Burst);
			m_at = now;
		}
		if (m_tokens < 1.)
			return false;
		m_tokens -= 1.;
		return true;
	}
	bool m_started = false;
	double m_tokens = 0.;
	uint64_t m_at = 0;
};

struct OldLimitsBucket
{
	bool started = false;
	double tokens = 0.;
	uint64_t at = 0;
	bool take(const limits::Pace& pace, uint64_t now_ms)
	{
		if (!started)
		{
			started = true;
			tokens = double(pace.burst);
			at = now_ms;
		}
		else if (now_ms > at)
		{
			const double refilled = tokens + double(now_ms - at) / double(pace.interval_ms);
			tokens = refilled < double(pace.burst) ? refilled : double(pace.burst);
			at = now_ms;
		}
		if (tokens < 1.)
			return false;
		tokens -= 1.;
		return true;
	}
};

struct OldAllowance
{
	double tokens = 0;
	uint64_t at = 0;
	bool started = false;
};
void old_refill(OldAllowance& a, uint32_t burst, uint32_t per_min, uint64_t now_ms)
{
	if (!a.started)
	{
		a.started = true;
		a.tokens = double(burst);
		a.at = now_ms;
		return;
	}
	if (now_ms <= a.at)
		return;
	const double gained = double(now_ms - a.at) * double(per_min) / 60000.0;
	a.tokens = std::min(double(burst), a.tokens + gained);
	a.at = now_ms;
}

bool old_charge(OldAllowance& budget, uint32_t cost, const spawn::SpawnPolicy& policy, uint64_t now_ms)
{
	const double burst = double(policy.cost_burst);
	if (!budget.started)
	{
		budget.started = true;
		budget.tokens = burst;
		budget.at = now_ms;
	}
	else if (now_ms > budget.at)
	{
		budget.tokens += double(now_ms - budget.at) * double(policy.cost_per_sec) / 1000.0;
		budget.at = now_ms;
	}
	if (budget.tokens > burst)
		budget.tokens = burst;
	const double amount = double(spawn::charge_of(cost, policy));
	if (amount > budget.tokens)
		return false;
	budget.tokens -= amount;
	return true;
}
} // namespace

TEST(bucket_golden_lease_pacer)
{
	lease::SpawnPacer now_pacer;
	OldLeasePacer<lease::kSpawnPaceBurst, lease::kSpawnPaceMs> old_pacer;
	int refused = 0;
	for (const uint64_t t : clock_steps())
	{
		const bool a = now_pacer.take(t), b = old_pacer.take(t);
		CHECK_EQ(a, b);
		refused += a ? 0 : 1;
	}
	CHECK(refused > 0); // the sequence reaches an empty bucket
	now_pacer.reset();
	old_pacer.m_started = false;
	CHECK_EQ(now_pacer.take(5), old_pacer.take(5));
}

TEST(bucket_golden_client_pacer)
{
	limits::Pacer pacer;
	OldLimitsBucket old;
	const limits::Pace pace = limits::client_pace(*limits::client_rule(Msg::StateDumpRequest));
	int refused = 0;
	for (const uint64_t t : clock_steps())
	{
		const bool a = pacer.take(Msg::StateDumpRequest, t), b = old.take(pace, t);
		CHECK_EQ(a, b);
		refused += a ? 0 : 1;
	}
	CHECK(refused > 0);
}

TEST(bucket_golden_ledger_allowance_is_bit_exact)
{
	ledger::Allowance a;
	OldAllowance o;
	uint32_t burst = 500, per_min = 37;
	int i = 0;
	for (const uint64_t t : clock_steps())
	{
		if (++i == 300)
		{
			burst = 120; // a policy change: lower than what is in it
			per_min = 7;
		}
		ledger::refill(a, burst, per_min, t);
		old_refill(o, burst, per_min, t);
		CHECK(a.tokens == o.tokens);
		CHECK_EQ(a.at, o.at);
		CHECK_EQ(a.started, o.started);
		const double spend = double(i % 13);
		if (a.tokens >= spend)
		{
			a.tokens -= spend;
			o.tokens -= spend;
		}
	}
}

TEST(bucket_golden_spawn_budget_is_bit_exact)
{
	spawn::CostBudget budget;
	OldAllowance old;
	spawn::SpawnPolicy policy;
	policy.cost_burst = 5000;
	policy.cost_per_sec = 333;
	int i = 0, refused = 0;
	for (const uint64_t t : clock_steps())
	{
		if (++i == 300)
			policy.cost_burst = 800; // lowered: the next charge caps at it with no refill
		const uint32_t cost = uint32_t(150 + (i * 37) % 900);
		const bool a = spawn::charge(budget, cost, policy, t), b = old_charge(old, cost, policy, t);
		CHECK_EQ(a, b);
		CHECK(budget.tokens == old.tokens);
		CHECK_EQ(budget.at, old.at);
		refused += a ? 0 : 1;
	}
	CHECK(refused > 0);
}

TEST(bucket_clock_back_refills_nothing)
{
	TokenBucket b;
	const auto per_ms = [](uint64_t ms) { return double(ms); };
	b.refill(1000, 3., per_ms);
	CHECK(b.take() && b.take() && b.take() && !b.take());
	b.refill(900, 3., per_ms); // back: nothing comes in, the last refill time stays
	CHECK(!b.take());
	CHECK_EQ(b.at, uint64_t(1000));
	b.refill(1001, 3., per_ms);
	CHECK(b.take() && !b.take());
}
