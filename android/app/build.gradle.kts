plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.lmartinez.aitana.aitana"
    compileSdk = 36
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    // 🛡️ REPLICADO: Evita que Android comprima el formato de modelo
    androidResources {
        noCompress.add("litertlm")
    }

    defaultConfig {
        applicationId = "com.lmartinez.aitana.aitana"
        // 🔴 REPLICADO: LiteRT-LM exige mínimo 24, usamos 31 como tu proyecto exitoso
        minSdk = 31 
        targetSdk = 36
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            // TODO: Cuando vayas a publicar, replicaremos la lógica de tu key.properties
            signingConfig = signingConfigs.getByName("debug")
            
            // 📦 REPLICADO: Vital para que el build de release no rompa las librerías C++
            isMinifyEnabled = false
            isShrinkResources = false
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
        }
    }
}

flutter {
    source = "../.."
}

// 🧠 Dependencias del Cerebro LiteRT-LM
dependencies {
    // LiteRT-LM (Google AI Edge): Modern on-device LLM engine.
    // Supports .litertlm format for optimized inference.
    implementation("com.google.ai.edge.litertlm:litertlm-android:0.11.0")

    // 🧠 Pilar 2: Vector Embedding Support (LiteRT/TFLite)
    implementation("com.google.ai.edge.litert:litert:1.0.1")
    implementation("org.tensorflow:tensorflow-lite-support:0.4.4") {
        exclude(group = "org.tensorflow", module = "tensorflow-lite")
        exclude(group = "org.tensorflow", module = "tensorflow-lite-api")
    }

    // Google Play Services Location (para geofencing)
    implementation("com.google.android.gms:play-services-location:21.3.0")

    // Kotlin coroutines (explicit — ensures version alignment)
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.8.1")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-core:1.8.1")

    // WorkManager
    implementation("androidx.work:work-runtime-ktx:2.9.0")

    // CameraX core library using the camera2 implementation
    val cameraxVersion = "1.7.0-alpha01"
    // The following line is optional, as the core library is included indirectly by camera-camera2
    implementation("androidx.camera:camera-core:${cameraxVersion}")
    implementation("androidx.camera:camera-camera2:${cameraxVersion}")
    // If you want to additionally use the CameraX Lifecycle library
    implementation("androidx.camera:camera-lifecycle:${cameraxVersion}")
    // If you want to additionally use the CameraX VideoCapture library
    implementation("androidx.camera:camera-video:${cameraxVersion}")
    // If you want to additionally use the CameraX View class
    implementation("androidx.camera:camera-view:${cameraxVersion}")
    // If you want to additionally add CameraX ML Kit Vision Integration
    implementation("androidx.camera:camera-mlkit-vision:${cameraxVersion}")
    // If you want to additionally use the CameraX Extensions library
    implementation("androidx.camera:camera-extensions:${cameraxVersion}")

    // Needed for ListenableFuture resolution in CameraX
    implementation("com.google.guava:guava:31.1-android")
}

// NEW: Modern Kotlin compiler options for v2.0+
kotlin {
    compilerOptions {
        jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
    }
}
