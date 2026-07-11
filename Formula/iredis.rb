# typed: false
# frozen_string_literal: true

class Iredis < Formula
  include Language::Python::Virtualenv

  desc "Terminal client for Redis with auto-completion and syntax highlighting"
  homepage "https://github.com/amzyang/iredis"
  url "https://github.com/amzyang/iredis/archive/refs/tags/v2.2.2.tar.gz"
  version "2.2.2"
  sha256 "666230f7d07c13f74699ffd764f9c9568479a170a656b188b59ac84875b6ff96"
  license "BSD-3-Clause"

  depends_on "python@3.14"

  def install
    virtualenv_create(libexec, "python3.14")
    system libexec/"bin/python", "-m", "pip", "install", buildpath.to_s
    bin.install_symlink libexec/"bin/iredis"
    generate_completions_from_executable(bin/"iredis", shell_parameter_format: :click)
  end

  test do
    assert_match version.to_s, shell_output("#{bin}/iredis --version")
  end
end
