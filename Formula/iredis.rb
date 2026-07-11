# typed: false
# frozen_string_literal: true

class Iredis < Formula
  include Language::Python::Virtualenv

  desc "Terminal client for Redis with auto-completion and syntax highlighting"
  homepage "https://github.com/amzyang/iredis"
  url "https://github.com/amzyang/iredis/archive/56abfdd44001dc561b3e63facd738030086f8abb.tar.gz"
  version "1.16.1"
  sha256 "d23759a6c0c14f9f367542bb8ec4eac8f0e46a58efad2b3372478f6382072a7e"
  license "BSD-3-Clause"

  depends_on "python@3.13"

  def install
    virtualenv_create(libexec, "python3.13")
    system libexec/"bin/pip", "install", "--upgrade", "pip"
    system libexec/"bin/pip", "install", buildpath.to_s
    bin.install_symlink libexec/"bin/iredis"
  end

  test do
    assert_match version.to_s, shell_output("#{bin}/iredis --version")
  end
end
