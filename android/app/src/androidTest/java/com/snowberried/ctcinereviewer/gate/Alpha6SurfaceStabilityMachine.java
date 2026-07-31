package com.snowberried.ctcinereviewer.gate;

/**
 * AndroidTest-only stable Surface state machine. It has no Android dependency so the exact
 * implementation used by device tests can also be compiled and exercised by the host gate.
 */
public final class Alpha6SurfaceStabilityMachine {
    public static final long STABLE_INTERVAL_MS = 300L;

    public enum Outcome {
        WAITING,
        READY,
        TIMED_OUT
    }

    public enum Reason {
        NONE,
        ACTIVITY_INSTANCE_STALE,
        ACTIVITY_NOT_CURRENT,
        SURFACE_NOT_CURRENT,
        DECODER_SURFACE_UNAVAILABLE,
        ACTIVITY_INSTANCE_CHANGED,
        SURFACE_GENERATION_CHANGED,
        STABILITY_TIMEOUT
    }

    public static final class Observation {
        public final long observedAtMs;
        public final Integer activityInstanceId;
        public final boolean resumed;
        public final boolean finishing;
        public final boolean destroyed;
        public final boolean decorAttached;
        public final boolean surfacePresent;
        public final boolean surfaceValid;
        public final boolean decoderSurfaceAvailable;
        public final Long surfaceGeneration;

        public Observation(
                long observedAtMs,
                Integer activityInstanceId,
                boolean resumed,
                boolean finishing,
                boolean destroyed,
                boolean decorAttached,
                boolean surfacePresent,
                boolean surfaceValid,
                boolean decoderSurfaceAvailable,
                Long surfaceGeneration) {
            this.observedAtMs = observedAtMs;
            this.activityInstanceId = activityInstanceId;
            this.resumed = resumed;
            this.finishing = finishing;
            this.destroyed = destroyed;
            this.decorAttached = decorAttached;
            this.surfacePresent = surfacePresent;
            this.surfaceValid = surfaceValid;
            this.decoderSurfaceAvailable = decoderSurfaceAvailable;
            this.surfaceGeneration = surfaceGeneration;
        }
    }

    public static final class Decision {
        public final Outcome outcome;
        public final Reason reason;
        public final Integer candidateActivityInstanceId;
        public final Long candidateSurfaceGeneration;
        public final long stableSinceMs;

        private Decision(
                Outcome outcome,
                Reason reason,
                Integer candidateActivityInstanceId,
                Long candidateSurfaceGeneration,
                long stableSinceMs) {
            this.outcome = outcome;
            this.reason = reason;
            this.candidateActivityInstanceId = candidateActivityInstanceId;
            this.candidateSurfaceGeneration = candidateSurfaceGeneration;
            this.stableSinceMs = stableSinceMs;
        }
    }

    private Integer candidateActivityInstanceId;
    private Long candidateSurfaceGeneration;
    private long stableSinceMs = -1L;
    private Reason lastReason = Reason.STABILITY_TIMEOUT;

    public Decision observe(Observation observation, long deadlineMs) {
        if (observation.observedAtMs >= deadlineMs) {
            return decision(
                    Outcome.TIMED_OUT,
                    lastReason == Reason.NONE ? Reason.STABILITY_TIMEOUT : lastReason);
        }
        Reason readinessIssue = readinessIssue(observation);
        if (readinessIssue != Reason.NONE) {
            reset(readinessIssue);
            return decision(Outcome.WAITING, readinessIssue);
        }

        Reason transition = Reason.NONE;
        if (candidateActivityInstanceId != null
                && !candidateActivityInstanceId.equals(observation.activityInstanceId)) {
            transition = Reason.ACTIVITY_INSTANCE_CHANGED;
        } else if (candidateSurfaceGeneration != null
                && !candidateSurfaceGeneration.equals(observation.surfaceGeneration)) {
            transition = Reason.SURFACE_GENERATION_CHANGED;
        }
        if (candidateActivityInstanceId == null
                || candidateSurfaceGeneration == null
                || transition != Reason.NONE) {
            candidateActivityInstanceId = observation.activityInstanceId;
            candidateSurfaceGeneration = observation.surfaceGeneration;
            stableSinceMs = observation.observedAtMs;
            lastReason = transition;
            return decision(Outcome.WAITING, transition);
        }
        if (observation.observedAtMs - stableSinceMs >= STABLE_INTERVAL_MS) {
            lastReason = Reason.NONE;
            return decision(Outcome.READY, Reason.NONE);
        }
        return decision(Outcome.WAITING, lastReason);
    }

    public Decision validateLease(
            Observation observation,
            int expectedActivityInstanceId,
            long expectedSurfaceGeneration) {
        Reason readinessIssue = readinessIssue(observation);
        if (readinessIssue != Reason.NONE) {
            return decision(Outcome.WAITING, readinessIssue);
        }
        if (observation.activityInstanceId != expectedActivityInstanceId) {
            return decision(Outcome.WAITING, Reason.ACTIVITY_INSTANCE_CHANGED);
        }
        if (observation.surfaceGeneration != expectedSurfaceGeneration) {
            return decision(Outcome.WAITING, Reason.SURFACE_GENERATION_CHANGED);
        }
        return decision(Outcome.READY, Reason.NONE);
    }

    private Reason readinessIssue(Observation observation) {
        if (observation.activityInstanceId == null
                || observation.finishing
                || observation.destroyed) {
            return Reason.ACTIVITY_INSTANCE_STALE;
        }
        if (!observation.resumed || !observation.decorAttached) {
            return Reason.ACTIVITY_NOT_CURRENT;
        }
        if (!observation.surfacePresent
                || !observation.surfaceValid
                || observation.surfaceGeneration == null) {
            return Reason.SURFACE_NOT_CURRENT;
        }
        if (!observation.decoderSurfaceAvailable) {
            return Reason.DECODER_SURFACE_UNAVAILABLE;
        }
        return Reason.NONE;
    }

    private void reset(Reason reason) {
        candidateActivityInstanceId = null;
        candidateSurfaceGeneration = null;
        stableSinceMs = -1L;
        lastReason = reason;
    }

    private Decision decision(Outcome outcome, Reason reason) {
        return new Decision(
                outcome,
                reason,
                candidateActivityInstanceId,
                candidateSurfaceGeneration,
                stableSinceMs);
    }
}
