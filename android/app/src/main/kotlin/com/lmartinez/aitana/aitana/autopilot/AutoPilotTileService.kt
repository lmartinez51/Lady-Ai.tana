package com.lmartinez.aitana.aitana.autopilot

import android.graphics.drawable.Icon
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService
import com.lmartinez.aitana.aitana.R

class AutoPilotTileService : TileService() {
    override fun onTileAdded() {
        super.onTileAdded()
        pushTileState()
    }

    override fun onStartListening() {
        super.onStartListening()
        pushTileState()
    }

    override fun onClick() {
        super.onClick()
        val enabled = !AutoPilotStateStore.isUserEnabled(this)
        AutoPilotStateStore.setUserEnabled(this, enabled)
        AutoPilotStateStore.broadcastStateChanged(this)
        pushTileState(enabled)
    }

    private fun pushTileState(
        enabled: Boolean = AutoPilotStateStore.isUserEnabled(this)
    ) {
        val tile = qsTile ?: return
        val subtitle = subtitleFor(enabled)

        tile.label = TILE_LABEL
        tile.contentDescription = TILE_LABEL
        tile.subtitle = subtitle
        tile.stateDescription = subtitle
        tile.icon = Icon.createWithResource(this, R.drawable.ic_auto_pilot_tile)
        tile.state = stateFor(enabled)
        tile.updateTile()
    }

    private fun subtitleFor(enabled: Boolean): String =
        if (enabled) "Active" else "Off"

    private fun stateFor(enabled: Boolean): Int =
        if (enabled) Tile.STATE_ACTIVE else Tile.STATE_INACTIVE

    private companion object {
        const val TILE_LABEL = "Auto-Pilot"
    }
}
