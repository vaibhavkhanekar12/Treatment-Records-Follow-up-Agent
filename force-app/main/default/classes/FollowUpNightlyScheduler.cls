/**
 * Schedules the nightly evaluation. Guards against overlapping runs.
 *
 * Schedule once (Anonymous Apex, as the automation user):
 *   FollowUpNightlyScheduler.schedule(null);          // default 02:00 daily
 *   FollowUpNightlyScheduler.schedule('0 30 1 * * ?'); // custom cron
 */
@SuppressWarnings('PMD.ApexCRUDViolation') // AsyncApexJob is a system object without user CRUD.
public with sharing class FollowUpNightlyScheduler implements Schedulable {
    public static final String JOB_NAME = 'Treatment & Records Follow-up - Nightly Evaluation';
    public static final String DEFAULT_CRON = '0 0 2 * * ?';

    public void execute(SchedulableContext context) {
        run();
    }

    /** Starts the batch unless one is already queued or running. Returns the job Id, or null when skipped. */
    public static Id run() {
        Integer running = [
            SELECT COUNT()
            FROM AsyncApexJob
            WHERE
                JobType = 'BatchApex'
                AND ApexClass.Name = 'FollowUpEvaluationBatch'
                AND Status IN ('Holding', 'Queued', 'Preparing', 'Processing')
        ];
        if (running > 0) {
            return null;
        }
        return Database.executeBatch(new FollowUpEvaluationBatch(), FollowUpConfig.batchSize());
    }

    public static Id schedule(String cronExpression) {
        return System.schedule(JOB_NAME, String.isBlank(cronExpression) ? DEFAULT_CRON : cronExpression, new FollowUpNightlyScheduler());
    }
}
