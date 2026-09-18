#pragma once

namespace ChromePatch {
	class __declspec(dllexport) SimplePatternSearcher : public PatternSearcher {
	public:
		byte* SearchBytePattern(Patch& patch, byte* startAddr, size_t length) override;
	};
}
