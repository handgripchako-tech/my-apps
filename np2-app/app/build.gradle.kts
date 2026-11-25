plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

android {
    namespace = "com.chako.np2"
    compileSdk = 34
    // ビルド機に入っている NDK をそのまま使う（Actions では ANDROID_NDK_HOME）
    // ndkVersion も同じ NDK に合わせる（AGP既定の26.1と食い違うとCXX1100で失敗する）
    System.getenv("ANDROID_NDK_HOME")?.let {
        ndkPath = it
        ndkVersion = File(it).canonicalFile.name
    }

    defaultConfig {
        applicationId = "com.chako.np2"
        minSdk = 26
        targetSdk = 34
        versionCode = 1
        versionName = "0.1"
        ndk { abiFilters += listOf("arm64-v8a") }
        externalNativeBuild {
            cmake { arguments += listOf("-DANDROID_STL=c++_shared") }
        }
    }

    externalNativeBuild {
        cmake {
            path = file("src/main/cpp/CMakeLists.txt")
        }
    }

    // 毎回同じ署名にして、APK を上書きインストールできるようにする（個人用の固定キー）
    signingConfigs {
        getByName("debug") {
            storeFile = rootProject.file("debug.keystore")
            storePassword = "android"
            keyAlias = "androiddebugkey"
            keyPassword = "android"
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = false
            signingConfig = signingConfigs.getByName("debug")
        }
    }

    packaging {
        jniLibs {
            useLegacyPackaging = true
            pickFirsts += "**/libc++_shared.so"
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions {
        jvmTarget = "17"
    }
}
