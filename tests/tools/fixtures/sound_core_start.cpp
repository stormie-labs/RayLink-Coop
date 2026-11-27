// Executes the engine's own CSoundRender_CoreA::_initialize and CSoundRender_CoreA::run_silent (xrSound/SoundRender_CoreA.cpp),
// cut out by tests/tools/test_sound_core_start.py into sound_core_start.inc, over stand-ins for OpenAL, the device list and
// the stock core the class derives from.
//
// A game that finds no sound device at its launch (a remote desktop session that has not brought its audio up yet, a
// headset pulled out) quit with "OpenAL: Can't create sound device." before its window opened: a client of the server stand
// never reached its join. It now plays on with the silent core a map server uses. CHECK_OR_EXIT stops the scenario here
// (the real one ends the process), so a quit is a failure of the scenario, not a crash of the runner.
// One scenario per run: sound_core_start.exe <scenario>.
#include <cstdarg>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

#include "sound_core_procs.inc" // one pointer type and one variable per LOAD_PROC of the cut function

using u32 = unsigned;
using BOOL = int;
using LPCSTR = const char*;
using xr_string = std::string;
#define TRUE 1
#define FALSE 0
#define FUNCTION_CAST(T, p) ((T)(p))

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
struct quit
{
	std::string why;
};
} // namespace

std::vector<std::string> g_log;
void Msg(const char* format, ...)
{
	char line[1024];
	va_list args;
	va_start(args, format);
	std::vsnprintf(line, sizeof(line), format, args);
	va_end(args);
	g_log.emplace_back(line);
	std::printf("%s\n", line);
}
void Log(const char* text, u32 n) { Msg("%s%u", text, n); }
std::string make_string(const char* format, ...)
{
	char line[1024];
	va_list args;
	va_start(args, format);
	std::vsnprintf(line, sizeof(line), format, args);
	va_end(args);
	return line;
}
#define CHECK_OR_EXIT(expr, message) \
	do                               \
	{                                \
		if (!(expr))                 \
			throw quit{message};     \
	} while (0)
#define R_ASSERT2(expr, message)                 \
	do                                           \
	{                                            \
		if (!(expr))                             \
			throw quit{std::string(message)};    \
	} while (0)

template <class T> T* xr_new() { return new T(); }
template <class T> void xr_delete(T*& p)
{
	delete p;
	p = nullptr;
}

struct Fvector
{
	float x, y, z;
	void set(float a, float b, float c)
	{
		x = a;
		y = b;
		z = c;
	}
};
struct SListener
{
	Fvector position{}, prevVelocity{}, curVelocity{}, accVelocity{};
	Fvector orientation[2]{};
};

// OpenAL
struct ALCdevice
{
};
struct ALCcontext
{
};
using ALCchar = char;
using ALenum = int;
enum
{
	ALC_DEVICE_SPECIFIER,
	AL_POSITION,
	AL_VELOCITY,
	AL_ORIENTATION,
	AL_GAIN
};
bool g_open_ok = true;
bool g_context_ok = true;
int g_opens = 0;
int g_closes = 0;
ALCdevice g_device;
ALCcontext g_context;
ALCdevice* alcOpenDevice(const char*)
{
	++g_opens;
	return g_open_ok ? &g_device : nullptr;
}
int alcCloseDevice(ALCdevice* d)
{
	if (d)
		++g_closes;
	return 1;
}
ALCcontext* alcCreateContext(ALCdevice*, const int*) { return g_context_ok ? &g_context : nullptr; }
const ALCchar* alcGetString(ALCdevice*, int) { return ""; }
ALenum alGetError() { return 0; }
ALenum alcGetError(ALCdevice*) { return 0; }
int alcMakeContextCurrent(ALCcontext*) { return 1; }
void alListener3f(int, float, float, float) {}
void alListenerfv(int, const float*) {}
void alListenerf(int, float) {}
void* alGetProcAddress(const char*) { return nullptr; }
#define AC_CHK(expr) (expr)
#define A_CHK(expr) (expr)

// the device list (OpenALDeviceList.cpp): GetNumDevices and the choice of the default device
struct ALDeviceDesc
{
	const char* name;
	const char* name_al;
};
xr_string snd_device_name;
u32 g_devices = 1;
struct ALDeviceList
{
	ALDeviceDesc desc{"Default Device", "OpenAL Soft"};
	u32 GetNumDevices() const { return g_devices; }
	void SelectBestDevice()
	{
		if (snd_device_name.empty() && g_devices)
			snd_device_name = desc.name;
	}
	const ALDeviceDesc* GetDeviceDescByName(const char* name) const
	{
		return g_devices && snd_device_name == name && snd_device_name == desc.name ? &desc : nullptr;
	}
};

struct CConsole
{
	void Execute(const char*) {}
};
CConsole* Console = nullptr;
int psSoundTargets = 3;
bool psSoundSilent = false;

struct CSoundRender_Target
{
	virtual ~CSoundRender_Target() = default;
	virtual bool _initialize() = 0;
	virtual void _destroy() = 0;
};
struct CSoundRender_TargetA : CSoundRender_Target
{
	bool _initialize() override { return true; }
	void _destroy() override {}
};

// the stock core: its own _initialize loads the environment and the cache (the silent cache with psSoundSilent)
struct CSoundRender_Core
{
	BOOL bPresent = TRUE;
	SListener Listener;
	std::vector<CSoundRender_Target*> s_targets;
	int inherited_inits = 0;
	bool cache_silent = false;
	void _initialize(int)
	{
		++inherited_inits;
		bPresent = TRUE;
		cache_silent = psSoundSilent;
	}
};

class CSoundRender_CoreA : public CSoundRender_Core
{
	typedef CSoundRender_Core inherited;

public:
	ALCdevice* pDevice = nullptr;
	ALDeviceList* pDeviceList = nullptr;
	ALCcontext* pContext = nullptr;
	int effects = 0;
	void LoadEffect() { ++effects; }
	void run_silent(LPCSTR why);
	void _initialize(int stage);
};

#include "sound_core_start.inc"

namespace
{
bool logged(const char* part)
{
	for (const std::string& line : g_log)
		if (line.find(part) != std::string::npos)
			return true;
	return false;
}

// Sound.cpp CSound_manager_interface::_create: stage 0 at the engine's start, stage 1 after the console config
bool start(CSoundRender_CoreA& core)
{
	try
	{
		core._initialize(0);
		core._initialize(1);
		return true;
	}
	catch (const quit& q)
	{
		std::fprintf(stderr, "the game quits: %s\n", q.why.c_str());
		return false;
	}
}

void check_silent(CSoundRender_CoreA& core, bool started)
{
	check(started, "the game goes on");
	check(psSoundSilent, "the silent core");
	check(core.cache_silent, "the stock core starts with the silent cache");
	check(core.inherited_inits == 1, "the stock core starts once");
	check(core.bPresent == TRUE, "the core is present: its emitters simulate");
	check(!core.pDevice && !core.pContext, "no device and no context are held");
	check(core.s_targets.empty() && core.effects == 0, "no target and no effect on a device that is not there");
	check(logged("~ SOUND: ") && logged("the game runs without sound"), "the warning says why there is no sound");
	check(!logged("! "), "no error line");
}
} // namespace

int main(int argc, char** argv)
{
	const std::string scenario = argc > 1 ? argv[1] : "";
	CSoundRender_CoreA core;
	if (scenario == "device")
	{
		const bool started = start(core);
		check(started, "the game goes on");
		check(!psSoundSilent, "the sound card plays");
		check(g_opens == 1 && core.pDevice && core.pContext, "the device and its context are open");
		check(core.inherited_inits == 1 && !core.cache_silent, "the stock core starts once with the full cache");
		check(core.s_targets.size() == u32(psSoundTargets) && core.effects == 1, "the targets and the effect are made");
		check(!logged("~ SOUND: "), "no warning");
	}
	else if (scenario == "no-device")
	{
		g_devices = 0;
		check_silent(core, start(core));
		check(g_opens == 0, "nothing is opened");
		check(core.pDeviceList != nullptr, "the empty device list stays for the options");
		check(logged("lists no sound device"), "the reason: no device listed");
	}
	else if (scenario == "open-fails")
	{
		g_open_ok = false;
		check_silent(core, start(core));
		check(g_opens == 1 && g_closes == 0, "one open tried, nothing to close");
		check(logged("could not open the sound device"), "the reason: the open failed");
	}
	else if (scenario == "context-fails")
	{
		g_context_ok = false;
		check_silent(core, start(core));
		check(g_opens == 1 && g_closes == 1, "the opened device is closed again");
		check(logged("could not create a context"), "the reason: no context");
	}
	else if (scenario == "silent-asked")
	{
		psSoundSilent = true; // a map server (x_ray.cpp)
		const bool started = start(core);
		check(started, "the map server goes on");
		check(core.pDeviceList == nullptr && g_opens == 0, "no device list and no device");
		check(core.inherited_inits == 1 && core.cache_silent, "the stock core starts once with the silent cache");
		check(!logged("~ SOUND: "), "no warning: the silence was asked for");
	}
	else
	{
		std::fprintf(stderr, "unknown scenario '%s'\n", scenario.c_str());
		return 2;
	}
	return g_failures ? 1 : 0;
}
