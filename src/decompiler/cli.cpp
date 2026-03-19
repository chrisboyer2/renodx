#include <cstdlib>

#include <cassert>
#include <exception>
#include <filesystem>
#include <iostream>
#include <optional>
#include <ostream>
#include <string>
#include <vector>

#include "../utils/path.hpp"
#include "../utils/shader_compiler_directx.hpp"
#include "../utils/shader_decompiler_dxc.hpp"

namespace {

std::filesystem::path GetExecutablePath() {
  wchar_t file_name[MAX_PATH] = L"";
  GetModuleFileNameW(nullptr, file_name, ARRAYSIZE(file_name));
  return std::filesystem::path(file_name).lexically_normal();
}

std::filesystem::path FindRepoTool(const std::filesystem::path& file_name) {
  auto executable_path = GetExecutablePath();
  std::vector<std::filesystem::path> candidates = {
      std::filesystem::current_path() / "bin" / file_name,
      executable_path.parent_path() / file_name,
      executable_path.parent_path().parent_path().parent_path() / "bin" / file_name,
  };

  for (const auto& candidate : candidates) {
    if (renodx::utils::path::CheckExistsFile(candidate)) {
      return candidate;
    }
  }
  return {};
}

std::wstring QuoteArgument(const std::wstring& argument) {
  std::wstring quoted = L"\"";
  quoted += argument;
  quoted += L"\"";
  return quoted;
}

bool RunProcess(const std::filesystem::path& executable, const std::vector<std::wstring>& arguments) {
  std::wstring command_line = QuoteArgument(executable.wstring());
  for (const auto& argument : arguments) {
    command_line += L" ";
    command_line += QuoteArgument(argument);
  }

  std::vector<wchar_t> mutable_command_line(command_line.begin(), command_line.end());
  mutable_command_line.push_back(L'\0');

  STARTUPINFOW startup_info = {
      .cb = sizeof(startup_info),
  };
  PROCESS_INFORMATION process_information = {};

  auto working_directory = executable.parent_path().wstring();
  if (!CreateProcessW(
          executable.c_str(),
          mutable_command_line.data(),
          nullptr,
          nullptr,
          TRUE,
          0,
          nullptr,
          working_directory.empty() ? nullptr : working_directory.c_str(),
          &startup_info,
          &process_information)) {
    return false;
  }

  WaitForSingleObject(process_information.hProcess, INFINITE);

  DWORD exit_code = EXIT_FAILURE;
  GetExitCodeProcess(process_information.hProcess, &exit_code);

  CloseHandle(process_information.hThread);
  CloseHandle(process_information.hProcess);

  return exit_code == 0;
}

std::filesystem::path GetOutputPath(
    const std::filesystem::path& input_path,
    const std::optional<std::filesystem::path>& explicit_output,
    const std::filesystem::path& extension) {
  std::filesystem::path output_path;
  if (explicit_output.has_value()) {
    output_path = explicit_output.value();
    output_path.replace_extension(extension);
  } else {
    output_path = input_path;
    output_path.replace_extension(extension);
  }
  return output_path.lexically_normal();
}

bool TryExternalDecompiler(
    const std::filesystem::path& input_path,
    const std::filesystem::path& output_path,
    bool use_hlsl_output) {
  auto cmd_decompiler = FindRepoTool("cmd_Decompiler.exe");
  if (cmd_decompiler.empty()) {
    return false;
  }

  auto generated_path = input_path;
  generated_path.replace_extension(use_hlsl_output ? ".hlsl" : ".msasm");

  std::error_code error_code;
  std::filesystem::remove(generated_path, error_code);
  std::filesystem::create_directories(output_path.parent_path(), error_code);

  if (!RunProcess(cmd_decompiler, {
                                    use_hlsl_output ? L"--decompile" : L"--disassemble-ms",
                                    input_path.wstring(),
                                })) {
    return false;
  }

  if (!renodx::utils::path::CheckExistsFile(generated_path)) {
    return false;
  }

  if (generated_path != output_path) {
    std::filesystem::copy_file(
        generated_path,
        output_path,
        std::filesystem::copy_options::overwrite_existing,
        error_code);
    if (error_code) {
      return false;
    }
  }

  return true;
}

void EnsureOutputDirectory(const std::filesystem::path& output_path) {
  std::error_code error_code;
  std::filesystem::create_directories(output_path.parent_path(), error_code);
}

std::string ShaderModelString(const renodx::utils::shader::compiler::directx::DxilProgramVersion& version) {
  return std::format("{}_{}_{}", version.GetKindAbbr(), version.GetMajor(), version.GetMinor());
}

}  // namespace

int main(int argc, char** argv) {
  std::span<char*> arguments = {argv, argv + argc};
  std::vector<char*> paths;
  for (auto& argument : arguments.subspan(1)) {
    if (argument[0] != '-') {
      paths.push_back(argument);
    }
  }

  if (paths.size() < 1) {
    std::cerr << "USAGE: decomp.exe {cso} [{hlsl}] [--flatten] [-f] [--skip-existing] [-s] [--use-do-while]\n";
    std::cerr << "  Creates {hlsl} from the contents of {cso} when decompilation is available.\n";
    std::cerr << "  Legacy shaders may fall back to a .msasm disassembly.\n";
    return EXIT_FAILURE;
  }

  bool flatten = std::ranges::any_of(arguments, [](const std::string& argument) {
    return (argument == "--flatten" || argument == "-f");
  });
  bool skip_existing = std::ranges::any_of(arguments, [](const std::string& argument) {
    return (argument == "--skip-existing" || argument == "-s");
  });
  bool use_do_while = std::ranges::any_of(arguments, [](const std::string& argument) {
    return (argument == "--use-do-while");
  });

  auto input_path = std::filesystem::path(paths[0]).lexically_normal();
  auto explicit_output = paths.size() >= 2
                             ? std::optional<std::filesystem::path>(std::filesystem::path(paths[1]).lexically_normal())
                             : std::nullopt;

  std::vector<uint8_t> code;
  std::string disassembly;
  renodx::utils::shader::compiler::directx::DxilProgramVersion version;
  try {
    code = renodx::utils::path::ReadBinaryFile(input_path);
    version = renodx::utils::shader::compiler::directx::DecodeShaderVersion(code);
    disassembly = renodx::utils::shader::compiler::directx::DisassembleShader(code);
  } catch (const std::exception& ex) {
    std::cerr << '"' << paths[0] << '"' << ": " << ex.what() << '\n';
    return EXIT_FAILURE;
  }
  if (disassembly.empty()) {
    std::cerr << "Failed to disassemble shader.\n";
    return EXIT_FAILURE;
  }

  if (version.GetMajor() < 4) {
    auto output = GetOutputPath(input_path, explicit_output, ".msasm");
    if (skip_existing && renodx::utils::path::CheckExistsFile(output)) {
      std::cout << "Skipping " << output.string() << '\n';
      return EXIT_SUCCESS;
    }

    EnsureOutputDirectory(output);
    renodx::utils::path::WriteTextFile(output, disassembly);
    std::cout << '"' << paths[0] << '"' << " => " << output.string()
              << " (legacy " << ShaderModelString(version) << " disassembly)\n";
    return EXIT_SUCCESS;
  }

  if (version.GetMajor() < 6) {
    auto hlsl_output = GetOutputPath(input_path, explicit_output, ".hlsl");
    if (skip_existing && renodx::utils::path::CheckExistsFile(hlsl_output)) {
      std::cout << "Skipping " << hlsl_output.string() << '\n';
      return EXIT_SUCCESS;
    }

    if (TryExternalDecompiler(input_path, hlsl_output, true)) {
      std::cout << '"' << paths[0] << '"' << " => " << hlsl_output.string()
                << " (3Dmigoto decompiler)\n";
      return EXIT_SUCCESS;
    }

    auto disassembly_output = GetOutputPath(input_path, explicit_output, ".msasm");
    if (skip_existing && renodx::utils::path::CheckExistsFile(disassembly_output)) {
      std::cout << "Skipping " << disassembly_output.string() << '\n';
      return EXIT_SUCCESS;
    }

    if (TryExternalDecompiler(input_path, disassembly_output, false)) {
      std::cout << '"' << paths[0] << '"' << " => " << disassembly_output.string()
                << " (Microsoft disassembly fallback)\n";
      return EXIT_SUCCESS;
    }

    EnsureOutputDirectory(disassembly_output);
    renodx::utils::path::WriteTextFile(disassembly_output, disassembly);
    std::cout << '"' << paths[0] << '"' << " => " << disassembly_output.string()
              << " (internal disassembly fallback)\n";
    return EXIT_SUCCESS;
  }

  auto decompiler = renodx::utils::shader::decompiler::dxc::Decompiler();

  try {
    std::string decompilation = decompiler.Decompile(disassembly, {
                                                                      .flatten = flatten,
                                                                      .use_do_while = use_do_while,
                                                                  });

    if (decompilation.empty()) {
      return EXIT_FAILURE;
    }

    std::string output;

    output = GetOutputPath(input_path, explicit_output, ".hlsl").string();

    if (skip_existing) {
      if (renodx::utils::path::CheckExistsFile(output)) {
        std::cout << "Skipping " << output << '\n';
        return EXIT_SUCCESS;
      }
    }

    EnsureOutputDirectory(output);
    renodx::utils::path::WriteTextFile(output, decompilation);
    std::cout << '"' << paths[0] << '"' << " => " << output << '\n';

  } catch (const std::exception& ex) {
    std::cerr << '"' << paths[0] << '"' << ": " << ex.what() << '\n';
    return EXIT_FAILURE;
  } catch (const std::string& ex) {
    std::cerr << '"' << paths[0] << '"' << ": " << ex << '\n';
    return EXIT_FAILURE;
  } catch (...) {
    std::cerr << '"' << paths[0] << '"' << ": Unknown failure" << '\n';
    return EXIT_FAILURE;
  }

  return EXIT_SUCCESS;
}
