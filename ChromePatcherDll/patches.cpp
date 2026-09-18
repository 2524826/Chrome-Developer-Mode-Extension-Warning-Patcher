#include "stdafx.h"
#include "patches.hpp"

namespace ChromePatch {
	namespace {
		constexpr unsigned int FileHeader = 0xCE161D6F;
		constexpr unsigned int PatchHeader = 0x8A7C5000;
		constexpr int MaximumPatches = 64;
		constexpr int MaximumPatterns = 32;
		constexpr int MaximumPatternLength = 4096;
		constexpr int MaximumOffsets = 64;
		constexpr int MaximumNewBytes = 4096;

		template<typename T>
		T ReadValue(std::ifstream& file, const char* field) {
			T value{};
			if (!file.read(reinterpret_cast<char*>(&value), sizeof(value))) {
				throw std::runtime_error(std::string("Truncated ChromePatches.bin while reading ") + field);
			}
			return value;
		}

		int ReadCount(std::ifstream& file, int maximum, const char* field) {
			const int value = ReadValue<int>(file, field);
			if (value < 0 || value > maximum) {
				throw std::runtime_error(std::string("Invalid count for ") + field);
			}
			return value;
		}

		struct PlannedWrite {
			Patch* patch;
			byte* address;
			byte original;
			byte replacement;
			DWORD originalProtection{};
		};

		bool IsInside(const byte* address, size_t length, const byte* start, size_t size) {
			return address >= start && length <= size &&
				static_cast<size_t>(address - start) <= size - length;
		}

		bool MatchesAt(const PatchPattern& pattern, const byte* address) {
			for (size_t index = 0; index < pattern.pattern.size(); index++) {
				const byte expected = pattern.pattern[index];
				if (expected != 0xFF && address[index] != expected) {
					return false;
				}
			}
			return true;
		}

		bool SamePatterns(const std::vector<PatchPattern>& left, const std::vector<PatchPattern>& right) {
			if (left.size() != right.size()) {
				return false;
			}
			for (size_t index = 0; index < left.size(); index++) {
				if (left[index].pattern != right[index].pattern) {
					return false;
				}
			}
			return true;
		}

		std::set<byte*> FindPatternMatches(const std::vector<PatchPattern>& patterns,
			byte* textStart, size_t textSize) {
			std::set<byte*> matches;
			for (const PatchPattern& pattern : patterns) {
				if (pattern.pattern.empty() || pattern.pattern.size() > textSize) {
					throw std::runtime_error("A patch contains an invalid pattern length");
				}

				auto anchor = std::find_if(pattern.pattern.begin(), pattern.pattern.end(),
					[](byte value) { return value != 0xFF; });
				if (anchor == pattern.pattern.end()) {
					throw std::runtime_error("A patch pattern contains only wildcards");
				}
				const size_t anchorOffset = static_cast<size_t>(anchor - pattern.pattern.begin());
				byte* firstAnchor = textStart + anchorOffset;
				byte* lastAnchor = textStart + textSize - pattern.pattern.size() + anchorOffset;
				byte* cursor = firstAnchor;
				while (cursor <= lastAnchor) {
					const size_t remaining = static_cast<size_t>(lastAnchor - cursor) + 1;
					byte* found = static_cast<byte*>(std::memchr(cursor, *anchor, remaining));
					if (found == nullptr) {
						break;
					}
					byte* candidate = found - anchorOffset;
					if (MatchesAt(pattern, candidate)) {
						matches.insert(candidate);
					}
					cursor = found + 1;
				}
			}
			return matches;
		}

		std::wstring TrimTrailingSeparators(std::wstring path) {
			while (path.size() > 3 && (path.back() == L'\\' || path.back() == L'/')) {
				path.pop_back();
			}
			return path;
		}

		std::wstring ParentPath(const std::wstring& path) {
			const std::wstring trimmed = TrimTrailingSeparators(path);
			const size_t separator = trimmed.find_last_of(L"\\/");
			return separator == std::wstring::npos ? std::wstring() : trimmed.substr(0, separator);
		}

		std::wstring FileName(const std::wstring& path) {
			const std::wstring trimmed = TrimTrailingSeparators(path);
			const size_t separator = trimmed.find_last_of(L"\\/");
			return separator == std::wstring::npos ? trimmed : trimmed.substr(separator + 1);
		}

		bool TryParseVersion(const std::wstring& text, std::vector<unsigned long>& parts) {
			parts.clear();
			if (text.empty()) {
				return false;
			}
			size_t start = 0;
			while (start < text.size()) {
				const size_t end = text.find(L'.', start);
				const size_t length = (end == std::wstring::npos ? text.size() : end) - start;
				if (length == 0 || length > 10) {
					return false;
				}
				unsigned long value = 0;
				for (size_t index = start; index < start + length; index++) {
					if (!iswdigit(text[index])) {
						return false;
					}
					const unsigned long digit = static_cast<unsigned long>(text[index] - L'0');
					if (value > (ULONG_MAX - digit) / 10) {
						return false;
					}
					value = value * 10 + digit;
				}
				parts.push_back(value);
				if (end == std::wstring::npos) {
					break;
				}
				start = end + 1;
			}
			return !parts.empty();
		}

		int CompareVersions(std::vector<unsigned long> left, std::vector<unsigned long> right) {
			const size_t length = (std::max)(left.size(), right.size());
			left.resize(length);
			right.resize(length);
			for (size_t index = 0; index < length; index++) {
				if (left[index] < right[index]) return -1;
				if (left[index] > right[index]) return 1;
			}
			return 0;
		}

		bool VersionInRange(const std::wstring& actualText, const std::wstring& minimumText,
			const std::wstring& maximumText) {
			std::vector<unsigned long> actual;
			std::vector<unsigned long> minimum;
			if (!TryParseVersion(actualText, actual) || !TryParseVersion(minimumText, minimum) ||
				CompareVersions(actual, minimum) < 0) {
				return false;
			}
			if (maximumText == L"*") {
				return true;
			}
			std::vector<unsigned long> maximum;
			return TryParseVersion(maximumText, maximum) && CompareVersions(actual, maximum) <= 0;
		}

		bool IsCandidateModulePathCore(const std::wstring& applicationRoot,
			const std::wstring& moduleName, const std::wstring& minimumVersion,
			const std::wstring& maximumVersion, const std::wstring& path,
			std::wstring* version) {
			if (applicationRoot.empty() || moduleName.empty() ||
				_wcsicmp(FileName(path).c_str(), moduleName.c_str()) != 0) {
				return false;
			}
			const std::wstring versionDirectory = ParentPath(path);
			const std::wstring candidateRoot = TrimTrailingSeparators(ParentPath(versionDirectory));
			const std::wstring candidateVersion = FileName(versionDirectory);
			if (_wcsicmp(candidateRoot.c_str(), TrimTrailingSeparators(applicationRoot).c_str()) != 0 ||
				!VersionInRange(candidateVersion, minimumVersion, maximumVersion)) {
				return false;
			}
			if (version != nullptr) {
				*version = candidateVersion;
			}
			return true;
		}
	}

	bool ModuleSelector::IsCandidate(const wchar_t* applicationRoot, const wchar_t* moduleName,
		const wchar_t* minimumVersion, const wchar_t* maximumVersion, const wchar_t* path) {
		return applicationRoot != nullptr && moduleName != nullptr && minimumVersion != nullptr &&
			maximumVersion != nullptr && path != nullptr && IsCandidateModulePathCore(
				applicationRoot, moduleName, minimumVersion, maximumVersion, path, nullptr);
	}

	std::ostream& operator<<(std::ostream& os, const Patch& patch) {
		os << "(First Pattern: " << std::hex;
		if (!patch.patterns.empty()) {
			for (byte value : patch.patterns[0].pattern) {
				os << std::setw(2) << std::setfill('0') << static_cast<int>(value) << " ";
			}
		}
		os << "with PatchByte " << static_cast<int>(patch.patchByte) << ")" << std::dec;
		return os;
	}

	ReadPatchResult Patches::ReadPatchFile(const std::wstring& browserExePath) {
		ReadPatchResult result{};
		patches.clear();
		applicationRoot.clear();
		moduleName.clear();
		minimumVersion.clear();
		maximumVersion.clear();
		ruleId.clear();

		const std::wstring browserRoot = TrimTrailingSeparators(ParentPath(browserExePath));
		const std::wstring patchFilePath = browserRoot + L"\\ChromePatches.bin";
		std::ifstream file(patchFilePath, std::ios::binary);
		if (!file.good()) {
			throw std::runtime_error("ChromePatches.bin was not found beside the browser executable");
		}

		if (ReadUInteger(file) != FileHeader) {
			throw std::runtime_error("Unsupported ChromePatches.bin format; reinstall the forward-compatible patcher");
		}
		applicationRoot = TrimTrailingSeparators(MultibyteToWide(ReadString(file)));
		moduleName = MultibyteToWide(ReadString(file));
		minimumVersion = MultibyteToWide(ReadString(file));
		maximumVersion = MultibyteToWide(ReadString(file));
		ruleId = ReadString(file);
		if (applicationRoot.empty() || moduleName.empty() || minimumVersion.empty() ||
			maximumVersion.empty() || ruleId.empty()) {
			throw std::runtime_error("ChromePatches.bin contains an empty module selector field");
		}
		if (_wcsicmp(applicationRoot.c_str(), browserRoot.c_str()) != 0 ||
			_wcsicmp(moduleName.c_str(), L"msedge.dll") != 0 ||
			FileName(moduleName) != moduleName) {
			throw std::runtime_error("ChromePatches.bin module selector does not match this Edge installation");
		}
		std::vector<unsigned long> minimumParts;
		std::vector<unsigned long> maximumParts;
		if (!TryParseVersion(minimumVersion, minimumParts) ||
			(maximumVersion != L"*" && !TryParseVersion(maximumVersion, maximumParts))) {
			throw std::runtime_error("ChromePatches.bin contains an invalid version range");
		}

		int patchCount = 0;
		while (file.peek() != EOF) {
			if (++patchCount > MaximumPatches) {
				throw std::runtime_error("ChromePatches.bin contains too many patches");
			}
			if (ReadUInteger(file) != PatchHeader) {
				throw std::runtime_error("Invalid ChromePatches.bin patch header");
			}

			std::vector<PatchPattern> patterns;
			const int patternsSize = ReadCount(file, MaximumPatterns, "pattern count");
			if (patternsSize == 0) {
				throw std::runtime_error("Patch has no patterns");
			}
			for (int patternIndex = 0; patternIndex < patternsSize; patternIndex++) {
				const int patternLength = ReadCount(file, MaximumPatternLength, "pattern length");
				if (patternLength == 0) {
					throw std::runtime_error("Patch has an empty pattern");
				}
				std::vector<byte> pattern(static_cast<size_t>(patternLength));
				if (!file.read(reinterpret_cast<char*>(pattern.data()), pattern.size())) {
					throw std::runtime_error("Truncated ChromePatches.bin pattern");
				}
				patterns.push_back(PatchPattern{ pattern });
			}

			std::vector<int> offsets;
			const int offsetCount = ReadCount(file, MaximumOffsets, "offset count");
			if (offsetCount == 0) {
				throw std::runtime_error("Patch has no offsets");
			}
			for (int offsetIndex = 0; offsetIndex < offsetCount; offsetIndex++) {
				offsets.push_back(ReadValue<int>(file, "patch offset"));
			}

			const int newBytesCount = ReadCount(file, MaximumNewBytes, "new byte count");
			std::vector<byte> newBytes(static_cast<size_t>(newBytesCount));
			if (newBytesCount > 0 &&
				!file.read(reinterpret_cast<char*>(newBytes.data()), newBytes.size())) {
				throw std::runtime_error("Truncated ChromePatches.bin replacement bytes");
			}

			const byte origByte = ReadValue<byte>(file, "original byte");
			const byte patchByte = ReadValue<byte>(file, "replacement byte");
			const byte isSig = ReadValue<byte>(file, "signature flag");
			const int sigOffset = ReadValue<int>(file, "signature offset");
			if (isSig > 1) {
				throw std::runtime_error("Invalid signature flag");
			}

			Patch patch{ patterns, origByte, patchByte, offsets, newBytes, isSig > 0, sigOffset };
			patches.push_back(patch);
			std::cout << "Loaded patch: " << patch << std::endl;
		}
		if (patches.empty()) {
			throw std::runtime_error("ChromePatches.bin contains no enabled patches");
		}
		return result;
	}

	bool Patches::IsCandidateModulePath(const std::wstring& path, std::wstring* version) const {
		return IsCandidateModulePathCore(applicationRoot, moduleName, minimumVersion,
			maximumVersion, path, version);
	}

	std::wstring Patches::MultibyteToWide(const std::string& str) {
		if (str.empty()) {
			return std::wstring();
		}
		const int length = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, str.c_str(),
			static_cast<int>(str.length()), nullptr, 0);
		if (length <= 0) {
			throw std::runtime_error("ChromePatches.bin module path is not valid UTF-8");
		}
		std::wstring result(static_cast<size_t>(length), L'\0');
		if (!MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, str.c_str(),
			static_cast<int>(str.length()), result.data(), length)) {
			throw std::runtime_error("ChromePatches.bin module path conversion failed");
		}
		return result;
	}

	std::string Patches::ReadString(std::ifstream& file) {
		const int length = ReadCount(file, 32768, "string length");
		std::string value(static_cast<size_t>(length), '\0');
		if (length > 0 && !file.read(value.data(), value.size())) {
			throw std::runtime_error("Truncated ChromePatches.bin string");
		}
		return value;
	}

	unsigned int Patches::ReadUInteger(std::ifstream& file) {
		return _byteswap_ulong(ReadValue<unsigned int>(file, "header"));
	}

	int Patches::ApplyPatches() {
		if (chromeDll == nullptr || !IsCandidateModulePath(chromeDllPath)) {
			throw std::runtime_error("Target module does not satisfy the configured Edge root, name, or version range");
		}

		byte* imageBase = reinterpret_cast<byte*>(chromeDll);
		const IMAGE_DOS_HEADER* dos = reinterpret_cast<const IMAGE_DOS_HEADER*>(imageBase);
		if (dos->e_magic != IMAGE_DOS_SIGNATURE || dos->e_lfanew <= 0) {
			throw std::runtime_error("Target module has an invalid DOS header");
		}
		const IMAGE_NT_HEADERS64* nt = reinterpret_cast<const IMAGE_NT_HEADERS64*>(imageBase + dos->e_lfanew);
		if (nt->Signature != IMAGE_NT_SIGNATURE || nt->FileHeader.Machine != IMAGE_FILE_MACHINE_AMD64 ||
			nt->OptionalHeader.Magic != IMAGE_NT_OPTIONAL_HDR64_MAGIC) {
			throw std::runtime_error("Target module is not a valid x64 PE image");
		}

		const IMAGE_SECTION_HEADER* textHeader = nullptr;
		const IMAGE_SECTION_HEADER* sections = IMAGE_FIRST_SECTION(nt);
		for (WORD index = 0; index < nt->FileHeader.NumberOfSections; index++) {
			char name[IMAGE_SIZEOF_SHORT_NAME + 1]{};
			memcpy_s(name, sizeof(name), sections[index].Name, IMAGE_SIZEOF_SHORT_NAME);
			if (strcmp(name, ".text") == 0) {
				if (textHeader != nullptr) {
					throw std::runtime_error("Target module contains duplicate .text sections");
				}
				textHeader = &sections[index];
			}
		}
		if (textHeader == nullptr) {
			throw std::runtime_error("Target module has no .text section");
		}

		byte* textStart = imageBase + textHeader->VirtualAddress;
		const size_t textSize = textHeader->Misc.VirtualSize;
		if (textSize == 0 || textHeader->VirtualAddress >= nt->OptionalHeader.SizeOfImage ||
			textSize > nt->OptionalHeader.SizeOfImage - textHeader->VirtualAddress) {
			throw std::runtime_error("Target .text section is outside the image");
		}

		struct CachedMatches {
			const std::vector<PatchPattern>* patterns;
			std::set<byte*> matches;
		};
		std::vector<CachedMatches> matchCache;
		std::vector<PlannedWrite> plan;
		for (Patch& patch : patches) {
			if (patch.origByte == 0xFF) {
				throw std::runtime_error("A patch uses wildcard original bytes; refusing all writes");
			}
			if (!patch.newBytes.empty()) {
				throw std::runtime_error("A multi-byte patch has no complete expected-byte sequence; refusing all writes");
			}

			auto cached = std::find_if(matchCache.begin(), matchCache.end(), [&patch](const CachedMatches& entry) {
				return SamePatterns(*entry.patterns, patch.patterns);
			});
			if (cached == matchCache.end()) {
				matchCache.push_back(CachedMatches{ &patch.patterns,
					FindPatternMatches(patch.patterns, textStart, textSize) });
				cached = matchCache.end() - 1;
			}
			const std::set<byte*>& matches = cached->matches;
			if (matches.size() != 1) {
				throw std::runtime_error("Rule " + ruleId + " expected exactly one .text match, found " +
					std::to_string(matches.size()) + "; refusing all writes");
			}

			byte* match = *matches.begin();
			std::vector<byte*> candidates;
			for (int offset : patch.offsets) {
				if (offset < 0 || !IsInside(match, static_cast<size_t>(offset) + 1, textStart, textSize)) {
					continue;
				}
				byte* address = match + offset;
				if (patch.isSig) {
					if (!IsInside(address, sizeof(int), textStart, textSize)) {
						continue;
					}
					const int displacement = *reinterpret_cast<const int*>(address);
					const intptr_t destination = reinterpret_cast<intptr_t>(address) +
						static_cast<intptr_t>(displacement) + sizeof(int) + patch.sigOffset;
					address = reinterpret_cast<byte*>(destination);
				}
				if (IsInside(address, 1, textStart, textSize) && *address == patch.origByte) {
					candidates.push_back(address);
				}
			}
			std::sort(candidates.begin(), candidates.end());
			candidates.erase(std::unique(candidates.begin(), candidates.end()), candidates.end());
			if (candidates.size() != 1) {
				throw std::runtime_error("Rule " + ruleId +
					" did not find the expected original byte at exactly one write offset; refusing all writes");
			}

			for (const PlannedWrite& existing : plan) {
				if (existing.address == candidates[0]) {
					throw std::runtime_error("Patch plan contains overlapping writes; refusing all writes");
				}
			}
			plan.push_back(PlannedWrite{ &patch, candidates[0], patch.origByte, patch.patchByte });
		}

		std::vector<PlannedWrite*> applied;
		for (PlannedWrite& write : plan) {
			if (!VirtualProtect(write.address, 1, PAGE_EXECUTE_READWRITE, &write.originalProtection)) {
				break;
			}
			*write.address = write.replacement;
			applied.push_back(&write);
			const BOOL flushed = FlushInstructionCache(GetCurrentProcess(), write.address, 1);
			DWORD ignored{};
			const BOOL restored = VirtualProtect(write.address, 1, write.originalProtection, &ignored);
			if (!flushed || !restored || *write.address != write.replacement) {
				break;
			}
			write.patch->successfulPatch = true;
		}

		if (applied.size() != plan.size() ||
			std::any_of(plan.begin(), plan.end(), [](const PlannedWrite& write) { return !write.patch->successfulPatch; })) {
			std::cerr << "A write failed; rolling back the complete patch plan" << std::endl;
			for (auto iterator = applied.rbegin(); iterator != applied.rend(); ++iterator) {
				PlannedWrite* write = *iterator;
				DWORD currentProtection{};
				if (VirtualProtect(write->address, 1, PAGE_EXECUTE_READWRITE, &currentProtection)) {
					*write->address = write->original;
					FlushInstructionCache(GetCurrentProcess(), write->address, 1);
					DWORD ignored{};
					VirtualProtect(write->address, 1, write->originalProtection, &ignored);
				}
				write->patch->successfulPatch = false;
			}
			return 0;
		}

		std::cout << "Rule " << ruleId << " applied " << plan.size()
			<< " guarded patch write(s) transactionally" << std::endl;
		return static_cast<int>(plan.size());
	}
}
