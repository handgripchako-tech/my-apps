plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

android {
    namespace = "com.chako.launcher"
    compileSdk = 34

    defaultConfig {
        applicationId = "com.chako.launcher"
        minSdk = 26
        targetSdk = 34
        versionCode = 20
        versionName = "1.54"
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
            // 軽量化: コード・リソースを縮小（ライブラリ依存ゼロ）
            isMinifyEnabled = true
            isShrinkResources = true
            signingConfig = signingConfigs.getByName("debug")
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
