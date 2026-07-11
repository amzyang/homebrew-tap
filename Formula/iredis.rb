# typed: false
# frozen_string_literal: true

class Iredis < Formula
  include Language::Python::Virtualenv

  desc "Terminal client for Redis with auto-completion and syntax highlighting"
  homepage "https://github.com/amzyang/iredis"
  url "https://github.com/amzyang/iredis/archive/refs/tags/v2.1.0.tar.gz"
  version "2.1.0"
  sha256 "80045f8f71dcea935a6206de0ca4e7450f7b9a8891178f644a85828dd1ebb086"
  license "BSD-3-Clause"

  depends_on "python@3.14"

  def install
    virtualenv_create(libexec, "python3.14")
    system libexec/"bin/python", "-m", "pip", "install", buildpath.to_s
    bin.install_symlink libexec/"bin/iredis"
  end

  test do
    assert_match version.to_s, shell_output("#{bin}/iredis --version")
  end
end
