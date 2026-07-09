# SPDX-FileCopyrightText: 2026 Huang Rui <vowstar@gmail.com>
# SPDX-License-Identifier: MIT
{ fetchurl }:
let
  fetchMaven = { name, urls, hash, installPath }:
    with builtins;
    let
      firstUrl = head urls;
      otherUrls = filter (elem: elem != firstUrl) urls;
    in
    fetchurl {
      inherit name hash;
      passthru = { inherit installPath; };
      url = firstUrl;
      recursiveHash = true;
      downloadToTemp = true;
      postFetch = ''
        mkdir -p "$out"
        cp -v "$downloadedFile" "$out/${baseNameOf firstUrl}"
      '' + concatStringsSep "\n"
        (map
          (elem:
            let filename = baseNameOf elem; in ''
              downloadedFile=$TMPDIR/${filename}
              tryDownload ${elem} "$downloadedFile"
              cp -v "$TMPDIR/${filename}" "$out/"
            '')
          otherUrls);
    };
in
{
  "org.scala-lang_scala3-compiler_3-3.7.4" = fetchMaven {
    name = "org.scala-lang_scala3-compiler_3-3.7.4";
    urls = [
      "https://repo1.maven.org/maven2/org/scala-lang/scala3-compiler_3/3.7.4/scala3-compiler_3-3.7.4.jar"
      "https://repo1.maven.org/maven2/org/scala-lang/scala3-compiler_3/3.7.4/scala3-compiler_3-3.7.4.pom"
    ];
    hash = "sha256-Noi5+DYkkzboXqUd3ybu12gc77EO2RcLQcr7rq+0+b0=";
    installPath = "https/repo1.maven.org/maven2/org/scala-lang/scala3-compiler_3/3.7.4";
  };

  "org.scala-lang_scala3-sbt-bridge-3.7.4" = fetchMaven {
    name = "org.scala-lang_scala3-sbt-bridge-3.7.4";
    urls = [
      "https://repo1.maven.org/maven2/org/scala-lang/scala3-sbt-bridge/3.7.4/scala3-sbt-bridge-3.7.4.jar"
      "https://repo1.maven.org/maven2/org/scala-lang/scala3-sbt-bridge/3.7.4/scala3-sbt-bridge-3.7.4.pom"
    ];
    hash = "sha256-9j3lus9zQALeswYLILnHONcq9tzT9PxSWu6Y+QMrxzE=";
    installPath = "https/repo1.maven.org/maven2/org/scala-lang/scala3-sbt-bridge/3.7.4";
  };

  "org.scala-lang_scala3-interfaces-3.7.4" = fetchMaven {
    name = "org.scala-lang_scala3-interfaces-3.7.4";
    urls = [
      "https://repo1.maven.org/maven2/org/scala-lang/scala3-interfaces/3.7.4/scala3-interfaces-3.7.4.jar"
      "https://repo1.maven.org/maven2/org/scala-lang/scala3-interfaces/3.7.4/scala3-interfaces-3.7.4.pom"
    ];
    hash = "sha256-YgYLYLLfohKwNumtNS6zAtB87Ht3umVSyiO2KgH8BRY=";
    installPath = "https/repo1.maven.org/maven2/org/scala-lang/scala3-interfaces/3.7.4";
  };

  "org.scala-lang.modules_scala-asm-9.8.0-scala-1" = fetchMaven {
    name = "org.scala-lang.modules_scala-asm-9.8.0-scala-1";
    urls = [
      "https://repo1.maven.org/maven2/org/scala-lang/modules/scala-asm/9.8.0-scala-1/scala-asm-9.8.0-scala-1.jar"
      "https://repo1.maven.org/maven2/org/scala-lang/modules/scala-asm/9.8.0-scala-1/scala-asm-9.8.0-scala-1.pom"
    ];
    hash = "sha256-kS1WgHhTdFwkLcqw9gowkcHYWgIgypRv7NR7Fpp7VeY=";
    installPath = "https/repo1.maven.org/maven2/org/scala-lang/modules/scala-asm/9.8.0-scala-1";
  };

  "org.scala-lang_tasty-core_3-3.7.4" = fetchMaven {
    name = "org.scala-lang_tasty-core_3-3.7.4";
    urls = [
      "https://repo1.maven.org/maven2/org/scala-lang/tasty-core_3/3.7.4/tasty-core_3-3.7.4.jar"
      "https://repo1.maven.org/maven2/org/scala-lang/tasty-core_3/3.7.4/tasty-core_3-3.7.4.pom"
    ];
    hash = "sha256-tVEOi6v1XnK96Dh5flOwT6pIBbX5PxVSR9UI7qQwPCc=";
    installPath = "https/repo1.maven.org/maven2/org/scala-lang/tasty-core_3/3.7.4";
  };
}
