module Portage
  module Cli
    module BrowserProfile
      # The one place `Process.spawn` is called from this feature —
      # injectable (`spawn:`) so Profile's own specs never start a real
      # browser (docs/plans/buy-skill-and-local-browser.md Phase 6's own
      # "specs must not launch a real browser" rule).
      #
      # Flags: `--user-data-dir` is always the dedicated Portage profile
      # directory (never the browser's default one — Chrome 136+ refuses
      # remote debugging on the default profile anyway, and this never
      # tries), `--remote-debugging-port` is this profile's own fixed
      # port, and `--no-first-run`/`--no-default-browser-check` keep the
      # launch from popping up onboarding UI the first time. Detached
      # (its own process group, stdout/stderr discarded) so `portage
      # browser profile open` returns immediately rather than blocking on
      # the browser's own lifetime.
      class Launcher
        def initialize(spawn: ->(*args) { Process.spawn(*args) })
          @spawn = spawn
        end

        def launch(binary:, profile_dir:, port:, url: nil)
          argv = [binary, "--user-data-dir=#{profile_dir}", "--remote-debugging-port=#{port}",
                  "--no-first-run", "--no-default-browser-check"]
          argv << url if url
          pid = @spawn.call(*argv, %i[out err] => File::NULL, pgroup: true)
          Process.detach(pid)
          pid
        end
      end
    end
  end
end
