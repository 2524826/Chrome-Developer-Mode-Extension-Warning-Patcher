#pragma once

namespace ChromePatch {
	class PatternSearcher; // Forward declaration for PatchThreadDelegate

	struct ReadPatchResult { // Make sure to null-initialize all fields
		bool UsingWrongVersion{};
	};

	struct PatchPattern {
		std::vector<byte> pattern{};
		int searchOffset{};
	};

	struct Patch {
		std::vector<PatchPattern> patterns{};
		byte origByte{}, patchByte{};
		std::vector<int> offsets{};
		std::vector<byte> newBytes{};
		bool isSig{};
		int sigOffset{};
		bool finishedPatch{}, successfulPatch{};

		friend std::ostream& operator<<(std::ostream& os, const Patch& patch);
	};

	class __declspec(dllexport) ModuleSelector {
	public:
		static bool IsCandidate(const wchar_t* applicationRoot, const wchar_t* moduleName,
			const wchar_t* minimumVersion, const wchar_t* maximumVersion, const wchar_t* path);
	};

	class Patches {
	public:
		HMODULE chromeDll{};
		std::wstring chromeDllPath{};
		std::wstring applicationRoot{};
		std::wstring moduleName{};
		std::wstring minimumVersion{};
		std::wstring maximumVersion{};
		std::string ruleId{};
		std::vector<Patch> patches{};

		ReadPatchResult ReadPatchFile(const std::wstring& browserExePath);
		bool IsCandidateModulePath(const std::wstring& path, std::wstring* version = nullptr) const;
		int ApplyPatches();
	private:
		static std::wstring MultibyteToWide(const std::string& str);
		static std::string ReadString(std::ifstream& file);
		static unsigned int ReadUInteger(std::ifstream& file);
	};
	inline Patches patches;

	class PatternSearcher {
	public:
		virtual byte* SearchBytePattern(Patch& patch, byte* startAddr, size_t length) = 0;
	};
}
