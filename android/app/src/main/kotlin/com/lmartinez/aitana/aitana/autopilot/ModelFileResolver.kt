package com.lmartinez.aitana.aitana.autopilot

import android.content.Context
import android.util.Log
import java.io.File

object ModelFileResolver {
    private const val TAG = "MiniAitanaModel"

    fun modelExistsOnDisk(context: Context, baseName: String): Boolean {
        val base = modelDirectory(context)
        return File(base, "${baseName}_owned.litertlm").exists() ||
            File(base, "${baseName}.litertlm").exists()
    }

    fun resolveForConfig(context: Context, baseName: String): File {
        val base = modelDirectory(context)
        val ownedFile = File(base, "${baseName}_owned.litertlm")
        if (ownedFile.exists()) return ownedFile

        val shellFile = File(base, "${baseName}.litertlm")
        if (shellFile.exists()) return shellFile

        throw modelNotFound(context, baseName)
    }

    fun resolveForEngine(context: Context, baseName: String): File {
        val base = modelDirectory(context)
        val ownedFile = File(base, "${baseName}_owned.litertlm")
        if (ownedFile.exists()) {
            Log.i(TAG, "Using existing owned model file: ${ownedFile.name}")
            return ownedFile
        }

        val shellFile = File(base, "${baseName}.litertlm")
        if (!shellFile.exists()) throw modelNotFound(context, baseName)

        Log.i(TAG, "First run: transferring model ownership for '$baseName'...")
        shellFile.copyTo(ownedFile)
        shellFile.delete()
        Log.i(TAG, "Model ownership transfer complete")
        return ownedFile
    }

    fun configFile(context: Context): File =
        File(context.applicationContext.filesDir, "aitana_config.json")

    private fun modelDirectory(context: Context): File =
        context.applicationContext.getExternalFilesDir(null)
            ?: context.applicationContext.filesDir

    private fun modelNotFound(context: Context, baseName: String): IllegalStateException =
        IllegalStateException(
            "Model file '${baseName}.litertlm' not found. Push via ADB:\n" +
                "adb push ${baseName}.litertlm " +
                "/sdcard/Android/data/${context.packageName}/files/"
        )
}
