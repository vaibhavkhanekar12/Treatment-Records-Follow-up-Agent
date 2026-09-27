/**
 * Classifies inbound response text into Response_Classification__c categories.
 * FollowUpKeywordClassifier is the deterministic default; FollowUpEinsteinClassifier (agentforce package)
 * is registered through Follow_Up_Setting__mdt.Response_Classifier_Class__c.
 * Implementations MUST NOT perform DML.
 */
public interface IFollowUpResponseClassifier {
    List<FollowUpClassification> classify(List<FollowUpClassification.Request> requests);
}
