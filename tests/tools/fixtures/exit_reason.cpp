// Executes the engine's own xrDebug::do_exit (xrCore/xrDebugNew.cpp, the body of CHECK_OR_EXIT), cut out by
// tests/tools/test_exit_reason.py into exit_reason.inc, over stand-ins for the log, the dialog and the process end.
//
// A game started without the launcher's key showed the reason in its dialog only: the log ended in the console variables
// the crash handler dumps, with no word of why, and a stand that read the log saw a process that "ended by itself, exit
// code 1". The reason now reaches the log on every path. TerminateProcess throws here, so the scenario can look afterwards.
// One scenario per run: exit_reason.exe <scenario>.
#include <cstdarg>
#include <cstddef>
#include <cstdio>
#include <string>
#include <vector>

namespace
{
int g_failures = 0;
void check(bool ok, const char* what)
{
	if (!ok)
	{
		std::fprintf(stderr, "FAIL: %s\n", what);
		++g_failures;
	}
}
struct terminated
{
	unsigned code;
};
int g_handlers = 0;
int g_boxes = 0;
int g_flushes = 0;
bool g_launcher_key = false; // -silent_error_mode
} // namespace

std::vector<std::string> g_log;
void Msg(const char* format, ...)
{
	char line[2048];
	va_list args;
	va_start(args, format);
	std::vsnprintf(line, sizeof(line), format, args);
	va_end(args);
	g_log.emplace_back(line);
	std::printf("%s\n", line);
}
bool shared_str_initialized = true;
namespace xrLogger
{
void FlushLog() { ++g_flushes; }
} // namespace xrLogger

#define RAYLINK_ENGINE_VERSION "RayLink Engine test"
#define MB_OK 0u
#define MB_ICONERROR 0u
#define MB_SYSTEMMODAL 0u
int MessageBox(void*, const char*, const char*, unsigned)
{
	++g_boxes;
	return 1;
}
void* GetCurrentProcess() { return nullptr; }
int TerminateProcess(void*, unsigned code) { throw terminated{code}; }

class xrDebug
{
public:
	void (*handler)() = nullptr;
	bool m_silent_fatal = false; // a map server
	bool silent_fatal() const { return m_silent_fatal; }
	void do_exit(const std::string& message);
};
xrDebug Debug;
static bool no_dialog() { return Debug.silent_fatal() || g_launcher_key; }
static void silent_fatal_begin() {}

#include "exit_reason.inc"

namespace
{
bool logged(const char* part)
{
	for (const std::string& line : g_log)
		if (line.find(part) != std::string::npos)
			return true;
	return false;
}

unsigned quit_with(const char* message)
{
	Debug.handler = [] { ++g_handlers; };
	try
	{
		Debug.do_exit(message);
	}
	catch (const terminated& t)
	{
		return t.code;
	}
	check(false, "do_exit returns");
	return 0;
}
} // namespace

int main(int argc, char** argv)
{
	const std::string scenario = argc > 1 ? argv[1] : "";
	const char* reason = "OpenAL: Can't create sound device.";
	if (scenario == "dialog")
	{
		const unsigned code = quit_with(reason);
		check(code == 1 && g_handlers == 1 && g_flushes == 1, "the handlers run, the log is flushed, exit code 1");
		check(g_boxes == 1, "the player sees the dialog");
		check(logged("FATAL ERROR") && logged("[error]Description   : OpenAL: Can't create sound device."),
		      "the log names the reason too");
	}
	else if (scenario == "launcher-key")
	{
		g_launcher_key = true;
		const unsigned code = quit_with(reason);
		check(code == 1 && g_boxes == 0, "no dialog, exit code 1");
		check(logged("FATAL ERROR") && logged("[error]Description   : OpenAL: Can't create sound device."),
		      "the launcher's window reads the reason");
	}
	else if (scenario == "map-server")
	{
		Debug.m_silent_fatal = true;
		const unsigned code = quit_with(reason);
		check(code == 1 && g_boxes == 0, "no dialog, exit code 1");
		check(logged("! FATAL: OpenAL: Can't create sound device.") && !logged("FATAL ERROR"), "the map server's own line");
	}
	else if (scenario == "no-strings")
	{
		shared_str_initialized = false; // before the core's strings: Msg cannot run yet
		const unsigned code = quit_with(reason);
		check(code == 1 && g_boxes == 1 && g_log.empty(), "only the dialog");
	}
	else
	{
		std::fprintf(stderr, "unknown scenario '%s'\n", scenario.c_str());
		return 2;
	}
	return g_failures ? 1 : 0;
}
