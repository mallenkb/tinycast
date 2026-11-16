#!/bin/bash
# A Model file compiles into harnesses alone, so it may not reach UI frameworks or the app's owners.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

status=0
if imports=$(grep -rln 'import AppKit\|import SwiftUI\|import Cocoa' Tinycast/Features/*/Model/); then
    echo "✗ Features/*/Model/ may not import AppKit, SwiftUI or Cocoa:" >&2
    echo "$imports" >&2
    status=1
fi
# Comments are stripped first, so naming a coordinator in prose stays allowed.
if owners=$(perl -ne '
    (my $code = $_) =~ s{//.*}{};
    print "$ARGV:$.: $_" if $code =~ /\bAppCore\b|\b(?!NSFile)[A-Z]\w*Coordinator\b|\.\w*Coordinator\b/;
    close ARGV if eof;
' $(find Tinycast/Features/*/Model -name '*.swift')) && [ -n "$owners" ]; then
    echo "✗ Features/*/Model/ may not reach AppCore or a coordinator; inject what it needs:" >&2
    echo "$owners" >&2
    status=1
fi
exit $status
