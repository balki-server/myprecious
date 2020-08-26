# myprecious

Generate a Markdown report with information about your dependencies

## Supports

* Ruby Gems
* Python Packages

## Command Line Help

```bash
myprecious help
```

## Configuration

### CVE Vendor Blocking

Because the search for CVEs in NIST's NVD can turn up false-positive matches, especially for dependencies with generic names like "mail", myprecious can be configured to ignore CVEs whose CPEs identify particular vendor/product pairs.  To do this, a file named `.myprecious-cves.rb` must be put in the same directory as the target project's package configuration (either the current directory or specified with the `-C`/`--dir` option).  That file must be a Ruby file that outputs JSON to STDOUT.  An example would be:

```ruby
require 'json'

JSON.dump({
  blockedProducts: %w[
    apple:mail
    basercms:mail
    downline_goldmine:builder
  ],
}, $stdout)
```

Each entry in `blockedProducts` should be a *vendor:product* pair, just as it would appear in the irrelevant CPE(s).

## Installing bash completions

Run the `myprecious` executable file with the `--install-completions` flag.  It will both install completions for bash session launched in the future and provide the path to the bash script that can be `source`ed in any existing bash sessions to enable completion.  This command only needs to be run once.
