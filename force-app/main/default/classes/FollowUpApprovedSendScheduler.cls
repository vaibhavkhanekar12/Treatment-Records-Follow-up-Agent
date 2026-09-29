/**
 * Optional scheduled sender for recommendations already approved by a human.
 * Schedule this independently from the nightly evaluator.
 */
@SuppressWarnings('PMD.ApexCRUDViolation')
public with sharing class FollowUpApprovedSendScheduler implements Schedulable {
    public static final String JOB_NAME = 'Treatment & Records Follow-up - Approved Send';
    public static final String DEFAULT_CRON = '0 0 3 * * ?';

    public void execute(SchedulableContext context) {
        if (!hasRunnableBatch()) {
            Database.executeBatch(new FollowUpApprovedSendBatch(), 50);
        }
    }

    public static Id schedule(String cronExpression) {
        return System.schedule(
            JOB_NAME,
            String.isBlank(cronExpression) ? DEFAULT_CRON : cronExpression,
            new FollowUpApprovedSendScheduler()
        );
    }

    private static Boolean hasRunnableBatch() {
        for (AggregateResult ar : [
            SELECT COUNT(Id) total
            FROM AsyncApexJob
            WHERE JobType = 'BatchApex'
              AND ApexClass.Name = 'FollowUpApprovedSendBatch'
              AND Status IN ('Holding', 'Queued', 'Preparing', 'Processing')
        ]) {
            return ((Integer) ar.get('total')) > 0;
        }
        return false;
    }
}
