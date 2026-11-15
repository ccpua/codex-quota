-- Shortcuts / Automator: Run AppleScript.
-- If connected, disconnect and wait for that exact state before reconnecting.
-- AmneziaVPN 5.1 generates changing QML identifiers; match the ConnectButton class,
-- never its generated numeric suffix or the button's screen coordinates.
property connectButtonID : "AmneziaApplication.mainWindow.tabBarStackView.connectButton"

on run {input, parameters}
    tell application "AmneziaVPN" to activate
    my prepareWindow()
    set currentState to my waitForStableState(30)

    if currentState is "connected" then
        if not my pressIfState("connected") then error "按钮状态已改变，请重新运行。"
        -- A still-connected frame immediately after AXPress is not a failure.
        if not my waitForState("disconnected", 30) then error "30 秒内未能确认断开，请检查 AmneziaVPN。"
    else if currentState is not "disconnected" then
        error "未能读取 AmneziaVPN 连接按钮状态，请确认屏幕已解锁且应用界面可操作。"
    end if

    if not my pressIfState("disconnected") then error "连接前按钮状态已改变，请重新运行。"
    if my waitForState("connected", 60) then return "AmneziaVPN 已显示连接成功。"
    error "已点击连接，但 60 秒内未确认连接成功，请检查 AmneziaVPN。"
end run

on waitForStableState(maxSeconds)
    repeat maxSeconds times
        set currentState to my readState()
        if currentState is in {"connected", "disconnected"} then return currentState
        delay 1
    end repeat
    return "unknown"
end waitForStableState

on waitForState(expectedState, maxSeconds)
    repeat maxSeconds times
        if my readState() is expectedState then return true
        delay 1
    end repeat
    return false
end waitForState

on connectionButton()
    set matches to {}
    tell application "System Events"
        if not (exists process "AmneziaVPN") then return missing value
        tell process "AmneziaVPN"
            repeat with windowRef in windows
                set controls to entire contents of windowRef
                repeat with controlRef in controls
                    set actualID to missing value
                    try
                        set actualID to value of attribute "AXIdentifier" of controlRef
                    end try
                    if (role of controlRef) is "AXButton" then
                        if my isConnectionButtonID(actualID) then set end of matches to contents of controlRef
                    end if
                end repeat
            end repeat
        end tell
    end tell
    -- Ambiguous controls must never cause a click on an unrelated button.
    if (count of matches) is 1 then return item 1 of matches
    return missing value
end connectionButton

on isConnectionButtonID(actualID)
    if actualID is missing value then return false
    set idText to actualID as text
    if idText is my connectButtonID then return true
    return idText starts with "AmneziaApplication." and idText contains ".ConnectButton_QMLTYPE_"
end isConnectionButtonID

on stateForLabel(buttonLabel)
    if buttonLabel is in {"已连接", "Connected"} then return "connected"
    if buttonLabel is in {"连接", "Connect", "未连接", "已断开", "Disconnected"} then return "disconnected"
    return "unknown"
end stateForLabel

on buttonState(buttonRef)
    if buttonRef is missing value then return "unknown"
    tell application "System Events" to set buttonLabel to name of buttonRef
    return my stateForLabel(buttonLabel)
end buttonState

on readState()
    try
        return my buttonState(my connectionButton())
    on error messageText number errorNumber
        -- Qt replaces accessibility objects while changing the button label.
        -- Treat a stale/missing object as a transition and poll it again.
        if errorNumber is in {-1728, -1700} then return "unknown"
        error messageText number errorNumber
    end try
end readState

on pressIfState(expectedState)
    set buttonRef to my connectionButton()
    if my buttonState(buttonRef) is not expectedState then return false
    tell application "System Events"
        if not (enabled of buttonRef) then return false
        perform action "AXPress" of buttonRef
    end tell
    return true
end pressIfState

on hasMainWindow()
    tell application "System Events"
        tell process "AmneziaVPN"
            repeat with windowRef in windows
                if (name of windowRef) is "AmneziaVPN" then return true
            end repeat
        end tell
    end tell
    return false
end hasMainWindow

on prepareWindow()
    if my connectionButton() is not missing value then return
    tell application "System Events"
        tell process "AmneziaVPN"
            -- Activating this Qt app does not recreate a closed main window.
            -- Screen-sharing overlays may exist even with the main window closed.
            if not my hasMainWindow() then
                click menu bar item 1 of menu bar 2
                set trayMenu to menu 1 of menu bar item 1 of menu bar 2
                set shown to false
                repeat with itemName in {"显示 AmneziaVPN", "Show AmneziaVPN", "Show"}
                    if exists menu item (itemName as text) of trayMenu then
                        click menu item (itemName as text) of trayMenu
                        set shown to true
                        exit repeat
                    end if
                end repeat
                if not shown then error "请从托盘菜单显示 AmneziaVPN 主窗口。"
            end if

            repeat 20 times
                if my hasMainWindow() then exit repeat
                delay 0.25
            end repeat
            if not my hasMainWindow() then error "无法显示 AmneziaVPN 主窗口。"

            -- The saved page may be Settings; select the known Home tab first.
            repeat with windowRef in windows
                set controls to entire contents of windowRef
                repeat with controlRef in controls
                    set actualID to missing value
                    try
                        set actualID to value of attribute "AXIdentifier" of controlRef
                    end try
                    if actualID is "AmneziaApplication.mainWindow.tabBar.homeTabButton" then
                        perform action "AXPress" of controlRef
                        return
                    end if
                    if actualID is not missing value then
                        if (actualID as text) contains ".TabBarButtonType_QMLTYPE_" then
                            if (role of controlRef) is "AXRadioButton" and (name of controlRef) is in {"首页", "Home"} then
                                perform action "AXPress" of controlRef
                                return
                            end if
                        end if
                    end if
                end repeat
            end repeat
        end tell
    end tell
end prepareWindow
