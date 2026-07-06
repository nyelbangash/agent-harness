defmodule Harness.AttachmentsTest do
  use ExUnit.Case, async: true

  alias Harness.Attachments

  describe "safe_filename/1" do
    test "keeps a normal filename untouched" do
      assert Attachments.safe_filename("screenshot.png") == "screenshot.png"
    end

    test "strips directory components from a traversal attempt" do
      assert Attachments.safe_filename("../../../etc/passwd") == "passwd"
    end

    test "strips a leading absolute path" do
      assert Attachments.safe_filename("/etc/passwd") == "passwd"
    end

    test "falls back to a stable name for empty or dot-only input" do
      assert Attachments.safe_filename("") == "attachment"
      assert Attachments.safe_filename(".") == "attachment"
      assert Attachments.safe_filename("..") == "attachment"
    end

    test "falls back when a residual separator survives basename" do
      assert Attachments.safe_filename("a\\b") == "attachment"
    end
  end

  describe "upload_error_message/1" do
    test "maps known error atoms to readable messages" do
      assert Attachments.upload_error_message(:too_large) =~ "too large"
      assert Attachments.upload_error_message(:too_many_files) =~ "too many files"
      assert Attachments.upload_error_message(:not_accepted) =~ "unsupported"
    end

    test "falls back to stringifying unknown errors" do
      assert Attachments.upload_error_message(:something_else) == "something_else"
    end
  end

  describe "image?/1" do
    test "true for image content types" do
      assert Attachments.image?("image/png")
      assert Attachments.image?("image/jpeg")
    end

    test "false for non-image or missing content types" do
      refute Attachments.image?("text/plain")
      refute Attachments.image?(nil)
    end
  end

  describe "upload_opts/0" do
    test "matches the shared accept list, entry cap, and size cap" do
      opts = Attachments.upload_opts()

      assert opts[:accept] == Attachments.allowed_exts()
      assert opts[:max_entries] == 5
      assert opts[:max_file_size] == 15_000_000
    end
  end
end
