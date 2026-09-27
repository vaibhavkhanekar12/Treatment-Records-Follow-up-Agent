/**
 * Delivers APPROVED follow-up communications. The send service has already enforced approval,
 * permissions and record access before calling deliver().
 * External integrations (SMS, e-fax, telephony) implement this interface using Named Credentials /
 * External Credentials and are registered in Follow_Up_Setting__mdt (SMS_Channel_Class__c, Fax_Channel_Class__c).
 * Implementations must be bulk-safe (one call per list) and must not update the recommendations themselves.
 */
public interface IFollowUpChannel {
    List<FollowUpDeliveryResult> deliver(List<Follow_Up_Recommendation__c> recommendations);
}
