"""macOS AppleScript regression tests; never click UI or change a real VPN."""
import pathlib
import re
import subprocess
import tempfile


source = pathlib.Path(__file__).with_name('reconnect-vpn.applescript').read_text()


def run(command, text=None):
    result = subprocess.run(command, input=text, text=True, capture_output=True, timeout=20)
    if result.returncode:
        raise AssertionError(result.stderr)
    return result.stdout.strip()


def replace_handler(text, name, replacement):
    text, count = re.subn(rf'(?ms)^on {name}\([^\n]*\).*?^end {name}\b', lambda _: replacement, text)
    assert count == 1, name
    return text


with tempfile.TemporaryDirectory(prefix='reconnect-vpn-test-') as directory:
    folder = pathlib.Path(directory)
    original = folder / 'original.scpt'
    run(['osacompile', '-o', str(original)], source)
    driver = '''on run argv
        set s to load script POSIX file (item 1 of argv)
        if not (s's isConnectionButtonID("AmneziaApplication.mainWindow.tabBarStackView.connectButton")) then error "Legacy ID rejected"
        if not (s's isConnectionButtonID("AmneziaApplication.QQuickWindowQmlImpl_QML_85.StackViewType_QMLTYPE_73_QML_83.ConnectButton_QMLTYPE_123")) then error "5.1 ID rejected"
        if not (s's isConnectionButtonID("AmneziaApplication.QQuickWindowQmlImpl_QML_999.ConnectButton_QMLTYPE_567")) then error "Generated suffix must not be fixed"
        repeat with badID in {"OtherApplication.ConnectButton_QMLTYPE_123", "AmneziaApplication.any.HomeInfoButton_QMLTYPE_98", "AmneziaApplication.any.TabBarButtonType_QMLTYPE_70", missing value}
            if s's isConnectionButtonID(contents of badID) then error "Unrelated button accepted"
        end repeat
        repeat with labelText in {"已连接", "Connected"}
            if (s's stateForLabel(contents of labelText)) is not "connected" then error "Connected label rejected"
        end repeat
        repeat with labelText in {"连接", "Connect", "未连接", "已断开", "Disconnected"}
            if (s's stateForLabel(contents of labelText)) is not "disconnected" then error "Disconnected label rejected"
        end repeat
        repeat with labelText in {"连接中", "正在断开", "Connecting", "Reconnecting", "", missing value}
            if (s's stateForLabel(contents of labelText)) is not "unknown" then error "Transition must not permit a click"
        end repeat
        return "Passed identifier and label recognition"
    end run'''
    driver_file = folder / 'driver.applescript'
    driver_file.write_text(driver)
    print(run(['osascript', str(driver_file), str(original)]))

    # Keep the real readState handler and inject a stale AX reference below it.
    stale_source = replace_handler(source, 'connectionButton', '''on connectionButton()
        return "mock button"
    end connectionButton''')
    for code in [-1728, -1700, -1743]:
        fixture = replace_handler(stale_source, 'buttonState', f'''on buttonState(buttonRef)
            error "mock AX failure" number {code}
        end buttonState''')
        compiled = folder / f'error-{code}.scpt'
        run(['osacompile', '-o', str(compiled)], fixture)
        driver_file.write_text('''on run argv
            set s to load script POSIX file (item 1 of argv)
            try
                return s's readState()
            on error messageText number errorNumber
                return "error=" & errorNumber
            end try
        end run''')
        expected = 'unknown' if code in [-1728, -1700] else f'error={code}'
        assert run(['osascript', str(driver_file), str(compiled)]) == expected
    print('Passed: transient AX errors are retried; permission errors remain visible')

    # Replace every handler that can touch UI and accelerate only mocked waits.
    mocked = source.replace('tell application "AmneziaVPN" to activate', '-- No UI in tests.')
    mocked = mocked.replace('on run {input, parameters}', 'on recover(input, parameters)').replace('end run', 'end recover')
    mocked = mocked.replace('delay 1', 'delay 0.001')
    mocked = replace_handler(mocked, 'prepareWindow', 'on prepareWindow()\nreturn\nend prepareWindow')
    mocked = replace_handler(mocked, 'pressIfState', '''on pressIfState(expectedState)
        set end of testPresses to expectedState
        return true
    end pressIfState''')
    mocked = replace_handler(mocked, 'readState', '''on readState()
        set stateText to item testCursor of testStates
        if testCursor < (count of testStates) then set testCursor to testCursor + 1
        return stateText
    end readState''')
    cases = [
        ('delayed disconnect', ['connected', 'connected', 'disconnected', 'disconnected', 'connected'], ['connected', 'disconnected'], ''),
        ('initially disconnected', ['disconnected', 'disconnected', 'connected'], ['disconnected'], ''),
        ('transition before stable state', ['unknown', 'disconnected', 'connected'], ['disconnected'], ''),
        ('disconnect timeout', ['connected'], ['connected'], '30 秒内未能确认断开'),
        ('unrecognized UI', ['unknown'], [], '未能读取 AmneziaVPN 连接按钮状态'),
        ('connect timeout', ['disconnected'], ['disconnected'], '60 秒内未确认连接成功'),
    ]
    def apple_list(items):
        return '{' + ', '.join('"' + item + '"' for item in items) + '}'

    for index, (name, states, presses, expected_error) in enumerate(cases):
        fixture = 'property testStates : ' + apple_list(states) + '\nproperty testCursor : 1\nproperty testPresses : {}\n' + mocked
        compiled = folder / f'case-{index}.scpt'
        case_driver = '''on run
            set failureText to ""
            try
                my recover({}, {})
            on error messageText
                set failureText to messageText
            end try
            if testPresses is not EXPECTED_PRESSES then error ("Incorrect click sequence; count=" & (count of testPresses) & "; error=" & failureText)
            if EXPECTED_ERROR is "" then
                if failureText is not "" then error failureText
            else
                if failureText does not contain EXPECTED_ERROR then error "Expected timeout or recognition failure"
            end if
            return "Passed"
        end run'''.replace('EXPECTED_PRESSES', apple_list(presses)).replace('EXPECTED_ERROR', '"' + expected_error + '"')
        run(['osacompile', '-o', str(compiled)], fixture + '\n' + case_driver)
        run(['osascript', str(compiled)])
        print('Passed:', name)

print('No real shortcut, UI click or VPN reconnect was run.')
