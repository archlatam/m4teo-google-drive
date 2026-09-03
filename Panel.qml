import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Commons
import "Model.js" as Model

Panel {
  id: root
  moduleName: "m4teo.rclone-drive"
  ipcTarget: "m4teo.rclone-drive"
  manageIpc: false

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property color accent: "#6fbf73"
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property bool installed: rclone.installed
  // Color del indicador de actividad: borrar=urgent, descargar/sync=accent.
  readonly property color actColor: rclone.activity === "deleting" ? urgent : accent
  readonly property color iconColor: !rclone.installed ? dim
    : rclone.lastOk ? "#6fbf73"
    : foreground
  readonly property color barIconColor: !rclone.installed ? Qt.darker(bar ? bar.barForeground : Color.foreground, 1.55)
    : rclone.lastOk ? "#6fbf73"
    : bar ? bar.barForeground : Color.foreground

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  Service {
    id: rclone
    settings: root.settings
  }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { rclone.refresh(); return "ok" }
    function status(): string { return rclone.statusText }
    function sync(): string { if (rclone.installed) rclone.sync(); return "ok" }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    iconComponent: Component {
      Item {
        implicitWidth: Style.space(12)
        implicitHeight: Style.space(12)
        RcloneIcon {
          anchors.centerIn: parent
          iconSize: Style.space(12)
          color: root.barIconColor
          opacity: rclone.installed ? 1.0 : 0.6
        }
      }
    }
    onPressed: function(b) {
      if (b === Qt.RightButton) rclone.refresh()
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(440))
    contentHeight: panel.fittedContentHeight(Math.min(column.implicitHeight, Style.space(520)))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (t === "s" || t === "S") { if (rclone.installed) rclone.sync() }
        else if (t === "r" || t === "R") rclone.refresh()
      }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height

        Column {
          id: column
          width: panelFlick.width
          spacing: Style.space(12)

          PanelHero {
            title: "Rclone Drive Sync"
            meta: root.heroMeta
            foreground: root.foreground
            fontFamily: root.fontFamily
            iconComponent: Component {
              RcloneIcon {
                iconSize: Style.font.display
                color: root.iconColor
              }
            }
          }

          Text {
            visible: rclone.lastError !== ""
            width: parent.width
            text: rclone.lastError
            color: root.urgent
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          Text {
            visible: rclone.installed && !rclone.checking
            width: parent.width
            text: rclone.localCount + " downloaded locally · " + rclone.selectedCount + " of " + rclone.files.length + " selected"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }

          PanelSeparator {
            visible: rclone.installed
            foreground: root.foreground
          }

          RowLayout {
            width: parent.width
            spacing: Style.space(8)

            Button {
              text: rclone.syncing ? "Syncing…" : "Sync"
              enabled: rclone.installed && !rclone.busy && !rclone.syncing
              foreground: root.foreground
              fontFamily: root.fontFamily
              Layout.fillWidth: true
              onClicked: rclone.sync()
            }

            Button {
              text: "Refresh list"
              enabled: rclone.installed && !rclone.busy
              foreground: root.foreground
              fontFamily: root.fontFamily
              Layout.fillWidth: true
              onClicked: rclone.refresh()
            }
          }

          // Indicador de actividad visual y telemetría de descarga
          ColumnLayout {
            visible: rclone.activity !== "none" || rclone.progressActive
            width: parent.width
            spacing: Style.space(4)

            RowLayout {
              Layout.fillWidth: true
              spacing: Style.space(6)

              Item {
                Layout.preferredWidth: Style.space(16)
                Layout.preferredHeight: Style.space(16)

                Rectangle {
                  anchors.centerIn: parent
                  width: parent.height
                  height: parent.height
                  radius: Math.min(width, height) / 2
                  color: Qt.rgba(actColor.r, actColor.g, actColor.b, 0.15)
                }

                Text {
                  anchors.centerIn: parent
                  text: {
                    if (rclone.activity === "downloading" || rclone.progressActive) return ""
                    if (rclone.activity === "deleting") return ""
                    return ""
                  }
                  color: actColor
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                }
              }

              ColumnLayout {
                Layout.fillWidth: true
                spacing: Style.space(2)

                // Nombre de la operación y archivo específico que se está descargando
                Text {
                  Layout.fillWidth: true
                  text: {
                    if (rclone.activity === "downloading" || rclone.progressActive) {
                      var target = rclone.currentTransferTarget || rclone.activityName || "…"
                      var file = rclone.currentTransferFile
                      if (file && file !== target) {
                        return "Downloading: " + target + " → " + file
                      }
                      return "Downloading: " + target
                    } else if (rclone.activity === "deleting") {
                      return "Removing local copy: " + (rclone.activityName || "…")
                    } else if (rclone.activity === "syncing") {
                      return "Syncing with Google Drive…"
                    }
                    return ""
                  }
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  elide: Text.ElideRight
                }

                // Telemetría: Porcentaje, bytes, velocidad y tiempo restante (ETA)
                Text {
                  Layout.fillWidth: true
                  visible: rclone.activity === "downloading" || rclone.progressActive
                  text: {
                    var parts = []
                    parts.push(Math.round(rclone.progressPercent) + "%")
                    if (rclone.progressBytes !== "") parts.push(rclone.progressBytes)
                    if (rclone.progressSpeed !== "") parts.push(rclone.progressSpeed)
                    if (rclone.progressEta !== "") parts.push("ETA: " + rclone.progressEta)
                    return parts.join(" · ")
                  }
                  color: actColor
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  elide: Text.ElideRight
                }
              }
            }

            // Barra de progreso de descarga
            Rectangle {
              visible: rclone.activity === "downloading" || rclone.progressActive
              Layout.fillWidth: true
              implicitHeight: Style.space(5)
              radius: Math.min(width, height) / 2
              color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.12)
              clip: true

              Rectangle {
                readonly property double pct: Math.min(Math.max(rclone.progressPercent, 0), 100)
                width: parent.width * (pct / 100)
                height: parent.height
                radius: parent.radius
                color: root.accent
              }
            }

            // Lista visual de cola de descargas pendientes
            RowLayout {
              visible: rclone.downloadQueue.length > 1
              Layout.fillWidth: true
              spacing: Style.space(4)

              Text {
                text: ""
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }

              Text {
                Layout.fillWidth: true
                text: "Queued (" + (rclone.downloadQueue.length - 1) + " pending): " + rclone.downloadQueue.slice(1).join(", ")
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                elide: Text.ElideRight
              }
            }
          }

          PanelSectionHeader {
            visible: rclone.installed && rclone.files.length > 0
            text: "DRIVE ITEMS"
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          Text {
            visible: rclone.installed && rclone.files.length === 0 && !rclone.checking
            width: parent.width
            text: "No items in the Drive root."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }

          Column {
            id: filesColumn
            visible: rclone.files.length > 0
            width: parent.width
            spacing: Style.space(4)

            Repeater {
              model: rclone.files
              SyncRow {
                required property int index
                required property var modelData
                width: filesColumn.width
                entry: modelData
              }
            }
          }

          Text {
            visible: rclone.installed
            width: parent.width
            text: "Select to download ·  removes the local copy (keeps it in Drive) · S sync · R refresh"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            horizontalAlignment: Text.AlignHCenter
          }
        }
      }
    }
  }

  readonly property string heroMeta: !rclone.installed ? "rclone is not installed"
    : rclone.statusText

  component SyncRow: RowLayout {
    id: syncRow
    property var entry: null
    readonly property string entryName: entry ? String(entry.name || "Untitled") : "Untitled"
    readonly property bool hasLocal: Model.isLocal(entry)
    readonly property bool selected: entry ? (entry.selected === 1 || hasLocal) : false
    readonly property bool isDir: entry ? entry.isDir === true : false
    readonly property string state: Model.entryState(entry)
    readonly property color stateColor: Model.entryColor(state, root.foreground, root.dim, root.accent)

    width: parent.width
    spacing: Style.space(8)

    readonly property bool isCurrentDownloading: rclone.currentTransferTarget === entryName && (rclone.downloading || rclone.progressActive)
    readonly property bool isInQueue: rclone.downloadQueue.indexOf(entryName) >= 0

    // Checkbox cuadrado con borde visible y feedback de cola/descarga
    Rectangle {
      id: checkBox
      property bool checked: syncRow.selected || syncRow.hasLocal
      readonly property color checkColor: checked ? (syncRow.hasLocal ? root.accent : root.foreground) : root.foreground
      width: Style.space(18)
      height: Style.space(18)
      radius: Math.min(width, height) * 0.18
      color: checked ? Qt.rgba(checkColor.r, checkColor.g, checkColor.b, 0.18) : "transparent"
      border.color: syncRow.isCurrentDownloading ? root.accent : checkColor
      border.width: (checked || syncRow.isCurrentDownloading) ? 1 : Math.max(1, Style.normalBorderWidth)
      Layout.alignment: Qt.AlignVCenter

      Text {
        anchors.centerIn: parent
        text: {
          if (syncRow.isCurrentDownloading) return ""
          if (syncRow.isInQueue) return ""
          if (syncRow.hasLocal) return "✓"
          if (parent.checked) return "•"
          return ""
        }
        color: syncRow.isCurrentDownloading ? root.accent : checkBox.checkColor
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        visible: parent.checked || syncRow.isInQueue || syncRow.hasLocal
      }

      MouseArea {
        anchors.fill: parent
        cursorShape: Qt.PointingHandCursor
        onClicked: rclone.setSelected(syncRow.entryName, !syncRow.selected)
      }
    }

    Text {
      text: Model.fileGlyph(syncRow.entryName)
      color: syncRow.isCurrentDownloading ? root.accent : syncRow.stateColor
      font.family: root.fontFamily
      font.pixelSize: Style.font.icon
      Layout.alignment: Qt.AlignVCenter
    }

    ColumnLayout {
      Layout.fillWidth: true
      spacing: Style.space(1)

      Text {
        Layout.fillWidth: true
        text: syncRow.entryName
        color: syncRow.isCurrentDownloading ? root.accent : syncRow.stateColor
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        elide: Text.ElideRight
      }

      Text {
        Layout.fillWidth: true
        text: {
          if (syncRow.isCurrentDownloading) {
            var dlText = "Downloading… " + Math.round(rclone.progressPercent) + "%"
            if (rclone.progressSpeed !== "") dlText += " · " + rclone.progressSpeed
            return dlText
          }
          if (syncRow.isInQueue) {
            return "Queued for download"
          }
          return Model.entryMeta(syncRow.entry)
        }
        color: (syncRow.isCurrentDownloading || syncRow.state === "subido") ? root.accent : root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
      }
    }

    // Botón de papelera para eliminar la copia local en un solo clic
    Rectangle {
      id: trashBtn
      visible: syncRow.hasLocal
      Layout.preferredWidth: Style.space(26)
      Layout.preferredHeight: Style.space(26)
      radius: Style.space(5)
      color: trashHover.containsMouse ? Qt.rgba(1.0, 0.25, 0.25, 0.20) : "transparent"
      border.color: trashHover.containsMouse ? "#ff5555" : "transparent"
      border.width: 1
      Layout.alignment: Qt.AlignVCenter

      Text {
        anchors.centerIn: parent
        text: ""
        color: trashHover.containsMouse ? "#ff5555" : root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
      }

      MouseArea {
        id: trashHover
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: rclone.setSelected(syncRow.entryName, false)
      }
    }
  }
}
