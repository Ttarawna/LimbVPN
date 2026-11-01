"""Дорабатывает Android-проект, созданный командой `flutter create`:
кладёт наши файлы, подключает quietcore.aar, ставит minSdk 24, добавляет правила R8.
Запускается из корня репозитория."""
import pathlib
import re
import shutil
import sys

ROOT = pathlib.Path(".")
APP = ROOT / "android" / "app"
OVERLAY = ROOT / "android_overlay"
PACKAGE_DIR = APP / "src" / "main" / "kotlin" / "dev" / "quiet" / "quiet_vpn"

kts = APP / "build.gradle.kts"
groovy = APP / "build.gradle"
gradle = kts if kts.exists() else groovy
if not gradle.exists():
    sys.exit("Не найден android/app/build.gradle(.kts). Сначала нужен flutter create.")
is_kts = gradle == kts
text = gradle.read_text(encoding="utf-8")

if "dev.quiet.quiet_vpn" not in text:
    sys.exit("namespace/applicationId не dev.quiet.quiet_vpn: проверьте --org и --project-name")

# 1. minSdk 24 (нужен для библиотеки ядра)
if is_kts:
    text = re.sub(r"minSdk\s*=\s*[^\n]+", "minSdk = 24", text, count=1)
else:
    text = re.sub(r"minSdk(Version)?\s*=?\s*[^\n]+", "minSdkVersion 24", text, count=1)

# 2. Подключаем aar и правила R8 (без них JNI-классы ядра вырезаются)
if is_kts:
    text += """

dependencies {
    implementation(files("libs/quietcore.aar"))
}

android {
    buildTypes {
        getByName("release") {
            proguardFiles("proguard-rules.pro")
        }
    }
}
"""
else:
    text += """

dependencies {
    implementation files('libs/quietcore.aar')
}

android {
    buildTypes {
        release {
            proguardFiles 'proguard-rules.pro'
        }
    }
}
"""
gradle.write_text(text, encoding="utf-8")

(APP / "proguard-rules.pro").write_text(
    "-keep class go.** { *; }\n-keep class quietcore.** { *; }\n-dontwarn go.**\n",
    encoding="utf-8",
)

# 3. Наши Kotlin-файлы и манифест вместо сгенерированных
for old in (APP / "src" / "main" / "kotlin").rglob("MainActivity.*"):
    old.unlink()
PACKAGE_DIR.mkdir(parents=True, exist_ok=True)
for kt in sorted(OVERLAY.glob("*.kt")):
    shutil.copy(kt, PACKAGE_DIR / kt.name)
shutil.copy(OVERLAY / "AndroidManifest.xml", APP / "src" / "main" / "AndroidManifest.xml")

(APP / "libs").mkdir(parents=True, exist_ok=True)
(APP / "src" / "main" / "assets" / "geo").mkdir(parents=True, exist_ok=True)
print("Android-проект доработан:", gradle)
