"""Replay vehicle transitions through the real VRIK Lua update and recenter file.

Run with a Python environment containing lupa (LuaJIT 2.1 matches the mod host):
    python -m unittest discover -s tools/roomscale_tests -p test_vehicle_recenter.py
"""
from pathlib import Path
import tempfile
import unittest

from lupa.luajit21 import LuaRuntime

ROOT = Path(__file__).resolve().parents[2]
MOD = ROOT / "mods/cet/CyberpunkVRPort_VRIK"


class VehicleRecenterTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.request = Path(self.temp.name) / "vrik_recenter.ini"
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        self.g = self.lua.globals()
        self.g.test_dir = Path(self.temp.name).as_posix()
        self.g.package.path = MOD.as_posix() + "/?.lua;" + self.g.package.path
        self.lua.execute("""
            events = {}; observers = {}; logs = {}; errors = {}
            present = true; paused = false; pregame = false
            playerId = 42; mounted = false; car = true; state = 0
            failMount = false; failWrite = false
            function registerForEvent(name, fn) events[name] = fn end
            function registerHotkey() end
            function Observe(class, name, fn) observers[name] = fn end
            spdlog = {
                info = function(s) logs[#logs+1] = s end,
                error = function(s) errors[#errors+1] = s end,
            }
            CName = {new = function(s) return s end}
            function GetVRMouseYDisabled() return true end
            os.time = function() return 100 end
            local originalOpen = io.open
            io.open = function(name, mode)
                if failWrite and mode == 'w' then return nil, 'write denied' end
                return originalOpen(test_dir .. '/' .. name, mode)
            end
            Game = {
                GetPlayer = function()
                    if not present then return nil end
                    -- A fresh RTTI wrapper on every frame, as in the actual host.
                    return {
                        GetEntityID = function() return {hash = playerId} end,
                        GetFPPCameraComponent = function() return nil end,
                        GetPlayerStateMachineBlackboard = function()
                            return {GetInt = function(_, key)
                                assert(key == 'Vehicle'); return state
                            end}
                        end,
                    }
                end,
                GetAllBlackboardDefs = function()
                    return {PlayerStateMachine = {Vehicle = 'Vehicle'}}
                end,
                GetSystemRequestsHandler = function()
                    return {IsPreGame = function() return pregame end,
                            IsGamePaused = function() return paused end}
                end,
                GetMountedVehicle = function()
                    if failMount then error('vehicle state unavailable') end
                    if not mounted then return nil end
                    return {IsA = function(_, name)
                        assert(name == 'vehicleCarBaseObject'); return car
                    end}
                end,
            }
        """)
        self.lua.execute((MOD / "init.lua").read_text(encoding="utf-8"))
        self.g.events.onInit()

    def tick(self, seconds=0.1, hz=60):
        for _ in range(round(seconds * hz)):
            self.g.events.onUpdate(1 / hz)

    def count(self):
        if not self.request.exists():
            return 0
        return int(self.request.read_text().strip().split("=")[1]) - 100

    def mount(self, state=1):
        self.g.mounted, self.g.state = True, state
        self.g.events.onUpdate(0.01)

    def unmount(self):
        self.g.mounted, self.g.state = False, 0
        self.g.events.onUpdate(0.01)

    def test_entry_and_exit_wait_two_seconds_once(self):
        self.tick()
        self.g.state, self.g.mounted = 4, True
        self.tick(5)
        self.assertEqual(self.count(), 0, "must wait for entry animation")
        self.mount()
        self.tick(1.9)
        self.assertEqual(self.count(), 0)
        self.tick(0.1)
        self.assertEqual(self.count(), 1)
        self.tick(10)
        self.assertEqual(self.count(), 1)
        self.g.state, self.g.mounted = 4, False
        self.tick(5)
        self.assertEqual(self.count(), 1, "must wait for exit animation")
        self.unmount()
        self.tick(1.9)
        self.assertEqual(self.count(), 1)
        self.tick(0.1)
        self.assertEqual(self.count(), 2)
        self.assertEqual(len(self.g.errors), 0)

    def test_passenger_entry_and_combat_or_seat_changes(self):
        self.tick()
        self.mount(3)
        self.tick(2)
        self.assertEqual(self.count(), 1)
        for state in (2, 4, 3, 4, 1, 6, 7, 3):
            self.g.state = state
            self.tick(3)
        self.assertEqual(self.count(), 1)

    def test_pause_restarts_settling_delay(self):
        self.tick()
        self.mount()
        self.tick(1)
        self.g.paused = True
        self.tick(20)
        self.assertEqual(self.count(), 0)
        self.g.paused = False
        self.tick(1.9)
        self.assertEqual(self.count(), 0)
        self.tick(0.1)
        self.assertEqual(self.count(), 1)

    def test_quick_exit_replaces_pending_entry(self):
        self.tick()
        self.mount()
        self.tick(1)
        self.unmount()
        self.tick(1)
        self.assertEqual(self.count(), 0)
        self.tick(1)
        self.assertEqual(self.count(), 1)
        self.assertIn("car exit: HMD recenter requested", self.g.logs[len(self.g.logs)])

    def test_save_load_uses_existing_recenter_only(self):
        self.tick()
        self.mount()
        self.tick(1)
        self.g.observers.OnGameAttached()
        self.tick(3.4)
        self.assertEqual(self.count(), 0)
        self.tick(0.2)
        self.assertEqual(self.count(), 1)
        self.tick(5)
        self.assertEqual(self.count(), 1)
        self.unmount()
        self.tick(2)
        self.assertEqual(self.count(), 2)

    def test_missing_player_or_main_menu_cancels_pending(self):
        for field in ("present", "pregame"):
            self.tick()
            self.mount()
            self.tick(1)
            self.g[field] = field == "pregame"
            self.tick(5)
            self.assertEqual(self.count(), 0)
            self.g[field] = field == "present"
            self.g.mounted, self.g.state = False, 0
            self.tick(3)
            self.assertEqual(self.count(), 0)

    def test_new_player_does_not_inherit_pending_recenter(self):
        self.tick()
        self.mount()
        self.tick(1)
        self.g.playerId = 99
        self.g.mounted, self.g.state = False, 0
        self.tick(5)
        self.assertEqual(self.count(), 0)

    def test_mount_and_state_must_agree(self):
        self.tick()
        self.g.mounted = True
        self.tick(5)  # Mount attached before state leaves Default.
        self.assertEqual(self.count(), 0)
        self.mount()
        self.tick(2)
        self.g.mounted = False
        self.tick(5)  # Mount detached before state reaches Default.
        self.assertEqual(self.count(), 1)
        self.unmount()
        self.tick(2)
        self.assertEqual(self.count(), 2)

    def test_bike_does_not_trigger_car_recenter(self):
        self.tick()
        self.g.car = False
        self.mount()
        self.tick(5)
        self.unmount()
        self.tick(5)
        self.assertEqual(self.count(), 0)

    def test_failed_file_write_is_logged_and_retried(self):
        self.tick()
        self.mount()
        self.g.failWrite = True
        self.tick(2)
        self.assertFalse(self.request.exists())
        self.assertIn("could not write", self.g.errors[1])
        self.g.failWrite = False
        self.tick(2)
        self.assertTrue(self.request.exists())
        self.assertIn("HMD recenter requested", self.g.logs[len(self.g.logs)])

    def test_api_error_does_not_turn_into_an_exit(self):
        self.tick()
        self.mount()
        self.tick(2)
        self.g.failMount = True
        self.tick(5)
        self.assertEqual(len(self.g.errors), 1)
        self.g.failMount = False
        self.tick(5)
        self.assertEqual(self.count(), 1)
        self.unmount()
        self.tick(2)
        self.assertEqual(self.count(), 2)

    def test_frame_stall_does_not_skip_settling_time(self):
        self.tick()
        self.mount()
        self.g.events.onUpdate(30)
        self.assertEqual(self.count(), 0)
        self.tick(1.9)
        self.assertEqual(self.count(), 1)


if __name__ == "__main__":
    unittest.main()
