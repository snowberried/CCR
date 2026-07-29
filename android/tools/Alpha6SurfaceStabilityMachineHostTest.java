package com.snowberried.ctcinereviewer.gate;

public final class Alpha6SurfaceStabilityMachineHostTest {
    private static int passed;

    public static void main(String[] args) {
        unchangedCurrentSurfaceBecomesStable();
        pastReadinessCannotBypassCurrentLoss();
        generationChangeRestartsStableWindow();
        finishingAndDestroyedActivitiesAreRejected();
        staleLeaseIsRejectedAndRecreatedActivityCanStabilize();
        decoderUnavailabilityIsRejected();
        timeoutIsBounded();
        System.out.println("Alpha 6 Surface stability host tests passed: " + passed);
    }

    private static void unchangedCurrentSurfaceBecomesStable() {
        Alpha6SurfaceStabilityMachine machine = new Alpha6SurfaceStabilityMachine();
        check(machine.observe(ready(0L, 1, 7L), 10_000L).outcome
                == Alpha6SurfaceStabilityMachine.Outcome.WAITING, "stable-start-waits");
        check(machine.observe(ready(299L, 1, 7L), 10_000L).outcome
                == Alpha6SurfaceStabilityMachine.Outcome.WAITING, "stable-299ms-waits");
        check(machine.observe(ready(300L, 1, 7L), 10_000L).outcome
                == Alpha6SurfaceStabilityMachine.Outcome.READY, "stable-300ms-ready");
    }

    private static void pastReadinessCannotBypassCurrentLoss() {
        Alpha6SurfaceStabilityMachine machine = new Alpha6SurfaceStabilityMachine();
        machine.observe(ready(0L, 1, 7L), 10_000L);
        check(machine.observe(ready(300L, 1, 7L), 10_000L).outcome
                == Alpha6SurfaceStabilityMachine.Outcome.READY, "past-ready-established");
        Alpha6SurfaceStabilityMachine.Decision lost =
                machine.observe(observation(301L, 1, 7L, true, false, false, true, true, false, true),
                        10_000L);
        check(lost.outcome == Alpha6SurfaceStabilityMachine.Outcome.WAITING
                        && lost.reason == Alpha6SurfaceStabilityMachine.Reason.SURFACE_NOT_CURRENT,
                "available-true-to-false-resets");
        check(machine.observe(ready(302L, 1, 7L), 10_000L).outcome
                == Alpha6SurfaceStabilityMachine.Outcome.WAITING, "stale-latch-cannot-pass");
        check(machine.observe(ready(601L, 1, 7L), 10_000L).outcome
                == Alpha6SurfaceStabilityMachine.Outcome.WAITING, "recreated-299ms-waits");
        check(machine.observe(ready(602L, 1, 7L), 10_000L).outcome
                == Alpha6SurfaceStabilityMachine.Outcome.READY, "recreated-300ms-ready");
    }

    private static void generationChangeRestartsStableWindow() {
        Alpha6SurfaceStabilityMachine machine = new Alpha6SurfaceStabilityMachine();
        machine.observe(ready(0L, 1, 7L), 10_000L);
        Alpha6SurfaceStabilityMachine.Decision changed =
                machine.observe(ready(200L, 1, 8L), 10_000L);
        check(changed.outcome == Alpha6SurfaceStabilityMachine.Outcome.WAITING
                        && changed.reason
                        == Alpha6SurfaceStabilityMachine.Reason.SURFACE_GENERATION_CHANGED,
                "generation-change-restarts");
        check(machine.observe(ready(499L, 1, 8L), 10_000L).outcome
                == Alpha6SurfaceStabilityMachine.Outcome.WAITING, "new-generation-299ms-waits");
        check(machine.observe(ready(500L, 1, 8L), 10_000L).outcome
                == Alpha6SurfaceStabilityMachine.Outcome.READY, "new-generation-300ms-ready");
    }

    private static void finishingAndDestroyedActivitiesAreRejected() {
        Alpha6SurfaceStabilityMachine finishingMachine = new Alpha6SurfaceStabilityMachine();
        Alpha6SurfaceStabilityMachine.Decision finishing =
                finishingMachine.observe(
                        observation(0L, 1, 7L, true, true, false, true, true, true, true),
                        10_000L);
        check(finishing.reason
                == Alpha6SurfaceStabilityMachine.Reason.ACTIVITY_INSTANCE_STALE,
                "finishing-activity-rejected");
        Alpha6SurfaceStabilityMachine destroyedMachine = new Alpha6SurfaceStabilityMachine();
        Alpha6SurfaceStabilityMachine.Decision destroyed =
                destroyedMachine.observe(
                        observation(0L, 1, 7L, true, false, true, true, true, true, true),
                        10_000L);
        check(destroyed.reason
                == Alpha6SurfaceStabilityMachine.Reason.ACTIVITY_INSTANCE_STALE,
                "destroyed-activity-rejected");
    }

    private static void staleLeaseIsRejectedAndRecreatedActivityCanStabilize() {
        Alpha6SurfaceStabilityMachine machine = new Alpha6SurfaceStabilityMachine();
        machine.observe(ready(0L, 1, 7L), 10_000L);
        check(machine.observe(ready(300L, 1, 7L), 10_000L).outcome
                == Alpha6SurfaceStabilityMachine.Outcome.READY, "original-activity-ready");
        Alpha6SurfaceStabilityMachine.Decision staleLease =
                machine.validateLease(ready(301L, 2, 8L), 1, 7L);
        check(staleLease.reason
                == Alpha6SurfaceStabilityMachine.Reason.ACTIVITY_INSTANCE_CHANGED,
                "stale-activity-lease-rejected");
        Alpha6SurfaceStabilityMachine.Decision recreated =
                machine.observe(ready(301L, 2, 8L), 10_000L);
        check(recreated.outcome == Alpha6SurfaceStabilityMachine.Outcome.WAITING,
                "recreated-current-activity-restarts");
        check(machine.observe(ready(601L, 2, 8L), 10_000L).outcome
                == Alpha6SurfaceStabilityMachine.Outcome.READY,
                "recreated-current-activity-used");
    }

    private static void decoderUnavailabilityIsRejected() {
        Alpha6SurfaceStabilityMachine machine = new Alpha6SurfaceStabilityMachine();
        Alpha6SurfaceStabilityMachine.Decision decision =
                machine.observe(
                        observation(0L, 1, 7L, true, false, false, true, true, true, false),
                        10_000L);
        check(decision.reason
                == Alpha6SurfaceStabilityMachine.Reason.DECODER_SURFACE_UNAVAILABLE,
                "decoder-surface-unavailable-rejected");
    }

    private static void timeoutIsBounded() {
        Alpha6SurfaceStabilityMachine machine = new Alpha6SurfaceStabilityMachine();
        machine.observe(
                observation(9_999L, 1, 7L, true, false, false, true, true, false, true),
                10_000L);
        Alpha6SurfaceStabilityMachine.Decision timedOut =
                machine.observe(
                        observation(10_000L, 1, 7L, true, false, false, true, true, false, true),
                        10_000L);
        check(timedOut.outcome == Alpha6SurfaceStabilityMachine.Outcome.TIMED_OUT,
                "timeout-at-deadline");
    }

    private static Alpha6SurfaceStabilityMachine.Observation ready(
            long nowMs, int instanceId, long generation) {
        return observation(
                nowMs, instanceId, generation, true, false, false, true, true, true, true);
    }

    private static Alpha6SurfaceStabilityMachine.Observation observation(
            long nowMs,
            int instanceId,
            long generation,
            boolean resumed,
            boolean finishing,
            boolean destroyed,
            boolean decorAttached,
            boolean surfacePresent,
            boolean surfaceValid,
            boolean decoderAvailable) {
        return new Alpha6SurfaceStabilityMachine.Observation(
                nowMs,
                instanceId,
                resumed,
                finishing,
                destroyed,
                decorAttached,
                surfacePresent,
                surfaceValid,
                decoderAvailable,
                generation);
    }

    private static void check(boolean condition, String name) {
        if (!condition) {
            throw new AssertionError("ALPHA6_SURFACE_STABILITY_HOST_TEST_FAILED:" + name);
        }
        passed += 1;
    }
}
