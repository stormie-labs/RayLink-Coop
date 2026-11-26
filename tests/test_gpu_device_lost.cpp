// RayLink unit tests: the note on a lost D3D device (engine/src/xrCore/gpu_device_lost.h). Report RL-5TE8-EFGE
// (2026-11-25): a FATAL in texture_load said only "The GPU device instance has been suspended. Use GetDeviceRemovedReason...";
// xrDebug::error2string now appends the renderer's note to that text, and only to the three lost-device codes.
// The expected HRESULT values are winerror.h's of Windows SDK 10.0.26100.0 (this file includes no Windows header).
#include "test_util.h"

#include "../engine/src/xrCore/gpu_device_lost.h"

#include <string>

namespace
{
std::string text_of(long code)
{
	char out[64];
	xr_gpu::reason_text(code, out, sizeof(out));
	return out;
}

std::string appended(const std::string& text, const char* note, size_t size)
{
	std::vector<char> buffer(size, 'x');
	for (size_t i = 0; i < text.size() && i < size; ++i)
		buffer[i] = text[i];
	if (text.size() < size)
		buffer[text.size()] = 0;
	xr_gpu::append_before_line_end(buffer.data(), size, note);
	return buffer.data();
}
} // namespace

TEST(gpu_lost_codes_are_the_sdk_values)
{
	CHECK_EQ(xr_gpu::code_ok, 0L);
	CHECK_EQ(static_cast<unsigned long>(xr_gpu::code_invalid_call), 0x887A0001UL);
	CHECK_EQ(static_cast<unsigned long>(xr_gpu::code_device_removed), 0x887A0005UL);
	CHECK_EQ(static_cast<unsigned long>(xr_gpu::code_device_hung), 0x887A0006UL);
	CHECK_EQ(static_cast<unsigned long>(xr_gpu::code_device_reset), 0x887A0007UL);
	CHECK_EQ(static_cast<unsigned long>(xr_gpu::code_driver_internal_error), 0x887A0020UL);
	CHECK_EQ(static_cast<unsigned long>(xr_gpu::code_out_of_memory), 0x8007000EUL);
}

TEST(gpu_lost_only_three_codes_get_the_note)
{
	CHECK(xr_gpu::is_device_lost(xr_gpu::code_device_removed));
	CHECK(xr_gpu::is_device_lost(xr_gpu::code_device_reset));
	CHECK(xr_gpu::is_device_lost(xr_gpu::code_device_hung));
	// error2string keeps the text of everything else: a file error (GetLastError), E_OUTOFMEMORY of a texture, S_OK
	CHECK(!xr_gpu::is_device_lost(xr_gpu::code_ok));
	CHECK(!xr_gpu::is_device_lost(xr_gpu::code_out_of_memory));
	CHECK(!xr_gpu::is_device_lost(xr_gpu::code_invalid_call));
	CHECK(!xr_gpu::is_device_lost(xr_gpu::code_driver_internal_error));
	CHECK(!xr_gpu::is_device_lost(2L));                                     // ERROR_FILE_NOT_FOUND
	CHECK(!xr_gpu::is_device_lost(static_cast<long>(0x80070057UL)));        // E_INVALIDARG
	CHECK(!xr_gpu::is_device_lost(static_cast<long>(0x887A0004UL)));        // DXGI_ERROR_UNSUPPORTED
	CHECK(!xr_gpu::is_device_lost(static_cast<long>(0x887A0026UL)));        // DXGI_ERROR_ACCESS_LOST
}

TEST(gpu_lost_reason_names)
{
	CHECK_EQ(text_of(xr_gpu::code_ok), std::string("S_OK"));
	CHECK_EQ(text_of(xr_gpu::code_device_hung), std::string("DXGI_ERROR_DEVICE_HUNG"));
	CHECK_EQ(text_of(xr_gpu::code_device_removed), std::string("DXGI_ERROR_DEVICE_REMOVED"));
	CHECK_EQ(text_of(xr_gpu::code_device_reset), std::string("DXGI_ERROR_DEVICE_RESET"));
	CHECK_EQ(text_of(xr_gpu::code_driver_internal_error), std::string("DXGI_ERROR_DRIVER_INTERNAL_ERROR"));
	CHECK_EQ(text_of(xr_gpu::code_invalid_call), std::string("DXGI_ERROR_INVALID_CALL"));
	CHECK_EQ(text_of(xr_gpu::code_out_of_memory), std::string("E_OUTOFMEMORY"));
	CHECK(xr_gpu::reason_name(static_cast<long>(0x887A002BUL)) == nullptr);
}

TEST(gpu_lost_reason_without_a_name_is_hex)
{
	CHECK_EQ(text_of(static_cast<long>(0x887A002BUL)), std::string("0x887A002B")); // DXGI_ERROR_ACCESS_DENIED
	CHECK_EQ(text_of(5L), std::string("0x00000005"));
	CHECK_EQ(text_of(-1L), std::string("0xFFFFFFFF"));

	char tiny[5];
	xr_gpu::reason_text(xr_gpu::code_device_hung, tiny, sizeof(tiny));
	CHECK_EQ(std::string(tiny), std::string("DXGI")); // cut, terminated
}

TEST(gpu_lost_note_with_video_memory)
{
	const unsigned long long mb = 1024ull * 1024ull;
	char out[256];
	xr_gpu::format_note(out, sizeof(out), xr_gpu::code_device_hung, true, 6512 * mb + 12345, 15872 * mb);
	CHECK_EQ(std::string(out),
	         std::string(" [GetDeviceRemovedReason: DXGI_ERROR_DEVICE_HUNG; local video memory: 6512 MB used of 15872 MB budget]"));

	// a card with more than 4 GB used: 64-bit counts, no wrap
	xr_gpu::format_note(out, sizeof(out), xr_gpu::code_driver_internal_error, true, 17000 * mb, 20000 * mb);
	CHECK_EQ(std::string(out), std::string(" [GetDeviceRemovedReason: DXGI_ERROR_DRIVER_INTERNAL_ERROR; local video memory: "
	                                       "17000 MB used of 20000 MB budget]"));
}

TEST(gpu_lost_note_without_video_memory)
{
	char out[256];
	xr_gpu::format_note(out, sizeof(out), xr_gpu::code_device_reset, false, 123, 456);
	CHECK_EQ(std::string(out), std::string(" [GetDeviceRemovedReason: DXGI_ERROR_DEVICE_RESET]"));

	xr_gpu::format_note(out, sizeof(out), static_cast<long>(0x887A002BUL), false, 0, 0);
	CHECK_EQ(std::string(out), std::string(" [GetDeviceRemovedReason: 0x887A002B]"));

	char small[12];
	xr_gpu::format_note(small, sizeof(small), xr_gpu::code_ok, false, 0, 0);
	CHECK_EQ(std::string(small), std::string(" [GetDevice")); // cut, terminated
}

TEST(gpu_lost_note_goes_before_the_system_line_break)
{
	const char* note = " [GetDeviceRemovedReason: DXGI_ERROR_DEVICE_HUNG]";
	const std::string system = "The GPU device instance has been suspended. Use GetDeviceRemovedReason to determine the appropriate action.";
	CHECK_EQ(appended(system + "\r\n", note, 1024), system + note + "\r\n");
	CHECK_EQ(appended(system, note, 1024), system + note); // no break: the note goes at the end
	CHECK_EQ(appended(system + "\n", note, 1024), system + note + "\n");
	CHECK_EQ(appended("", note, 1024), std::string(note));
	CHECK_EQ(appended("\r\n", note, 1024), std::string(note) + "\r\n");
}

TEST(gpu_lost_note_is_cut_never_the_break)
{
	const char* note = " [GetDeviceRemovedReason: DXGI_ERROR_DEVICE_HUNG]";
	// 10 chars of room in all: "abc" + 4 of the note + "\r\n" + terminator
	CHECK_EQ(appended("abc\r\n", note, 10), std::string("abc [Ge\r\n"));
	// no room for the note at all: the text stays as it was
	CHECK_EQ(appended("abcdefg\r\n", note, 10), std::string("abcdefg\r\n"));
	// a text that filled its buffer: terminated first, its last char goes
	CHECK_EQ(appended("abcdefghij", note, 10), std::string("abcdefghi"));
	// size 1: only the terminator
	CHECK_EQ(appended("abc", note, 1), std::string());
}
