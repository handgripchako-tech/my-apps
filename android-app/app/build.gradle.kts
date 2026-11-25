plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

android {
    namespace = "com.chako.testserver"
    compileSdk = 34

    defaultConfig {
        applicationId = "com.chako.testserver"
        minSdk = 26
        targetSdk = 34
        versionCode = 3
        versionName = "1.2"
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

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions {
        jvmTarget = "17"
    }
}

dependencies {
    implementation("androidx.webkit:webkit:1.11.0")
}
