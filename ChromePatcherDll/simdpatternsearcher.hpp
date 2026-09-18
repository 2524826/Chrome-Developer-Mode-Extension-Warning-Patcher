#pragma once

namespace ChromePatch {
	class __declspec(dllexport) SimdPatternSearcher : public PatternSearcher {
	public:
		byte* SearchBytePattern(Patch& patch, byte* startAddr, size_t length) override;
		static bool IsCpuSupported();
	};
}
