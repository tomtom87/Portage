module Portage
  module Cli
    # docs/plans/handoff-reconcile.md Phase 3's "macos" notify channel — a
    # native notification banner for a settled handoff. Opt-in (see
    # ReconcileNotify), and a no-op off Darwin.
    #
    # `system("osascript", "-e", script)` in array form, never an
    # interpolated shell string — same posture as CheckoutHandoff's
    # `open`/`xdg-open`. The injection surface that remains is the
    # AppleScript source itself: `title`/`message` come from a merchant
    # name and an amount, both untrusted, so they're never spliced into the
    # script raw. #applescript_string escapes backslashes and double quotes
    # before interpolating, so a merchant name like `foo" & do shell script
    # "rm -rf ~" & "` can't break out of its quoted string and run as
    # AppleScript.
    class MacosNotifier
      def call(title:, message:)
        return false unless RbConfig::CONFIG["host_os"] =~ /darwin/i

        script = "display notification #{applescript_string(message)} with title #{applescript_string(title)}"
        !!system("osascript", "-e", script)
      rescue StandardError
        false
      end

      private

      def applescript_string(text)
        # Block form, not a replacement string: gsub treats "\\" in a
        # replacement *string* as a backreference escape, which would
        # collapse a literal backslash right back down to one.
        escaped = text.to_s.gsub("\\") { "\\\\" }.gsub('"') { '\"' }
        "\"#{escaped}\""
      end
    end
  end
end
