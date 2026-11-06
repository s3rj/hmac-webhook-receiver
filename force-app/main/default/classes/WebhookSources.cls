/**
 * Source configuration (Webhook_Source__mdt) and secrets (Webhook_Secret__c), with test overrides.
 */
public with sharing class WebhookSources {
    /** Days a Processed, Ignored, or Rejected event is kept when the source does not say. */
    public static final Integer DEFAULT_RETENTION_DAYS = 30;

    public class Source {
        public String name { get; private set; }
        public String signatureHeader { get; private set; }
        public String signaturePrefix { get; private set; }
        public WebhookSignature.Scheme scheme { get; private set; }
        public String timestampHeader { get; private set; }
        public Integer toleranceSeconds { get; private set; }
        public String eventIdHeader { get; private set; }
        public String eventIdPath { get; private set; }
        public String eventTypeHeader { get; private set; }
        public String eventTypePath { get; private set; }
        public Boolean active { get; private set; }
        public Integer retentionDays { get; private set; }

        public Source(String name) {
            this.name = name;
            this.scheme = WebhookSignature.Scheme.BODY;
            this.active = true;
            this.retentionDays = DEFAULT_RETENTION_DAYS;
        }

        public Source(Webhook_Source__mdt record) {
            this(record.DeveloperName);
            signatureHeader = record.Signature_Header__c;
            signaturePrefix = record.Signature_Prefix__c;
            scheme = WebhookSignature.schemeFor(record.Scheme__c);
            timestampHeader = record.Timestamp_Header__c;
            toleranceSeconds = record.Tolerance_Seconds__c == null ? null : record.Tolerance_Seconds__c.intValue();
            eventIdHeader = record.Event_Id_Header__c;
            eventIdPath = record.Event_Id_Path__c;
            eventTypeHeader = record.Event_Type_Header__c;
            eventTypePath = record.Event_Type_Path__c;
            active = record.Active__c;
            if (record.Retention_Days__c != null && record.Retention_Days__c >= 1) {
                retentionDays = record.Retention_Days__c.intValue();
            }
        }

        public Source withSignature(String header, String prefix, WebhookSignature.Scheme scheme) {
            this.signatureHeader = header;
            this.signaturePrefix = prefix;
            this.scheme = scheme;
            return this;
        }

        public Source withTimestamp(String header, Integer tolerance) {
            this.timestampHeader = header;
            this.toleranceSeconds = tolerance;
            return this;
        }

        public Source withEventId(String header, String path) {
            this.eventIdHeader = header;
            this.eventIdPath = path;
            return this;
        }

        public Source withEventType(String header, String path) {
            this.eventTypeHeader = header;
            this.eventTypePath = path;
            return this;
        }

        public Source withActive(Boolean active) {
            this.active = active;
            return this;
        }

        public Source withRetention(Integer days) {
            this.retentionDays = days;
            return this;
        }

        /** The headers worth keeping on the event record. */
        public List<String> interestingHeaders() {
            List<String> names = new List<String>();
            for (String name : new List<String>{ signatureHeader, timestampHeader, eventIdHeader, eventTypeHeader }) {
                if (String.isNotBlank(name)) {
                    names.add(name);
                }
            }
            return names;
        }
    }

    @TestVisible
    private static Map<String, Source> sourceOverrides;
    @TestVisible
    private static Map<String, String> secretOverrides;
    @TestVisible
    private static Map<String, String> previousSecretOverrides;
    private static Map<String, Source> cache;

    /** The source for a URL segment (case-insensitive), or null if none is configured or it is inactive. */
    public static Source find(String name) {
        if (String.isBlank(name)) {
            return null;
        }
        Source source = sources().get(name.toLowerCase());
        return source != null && source.active ? source : null;
    }

    /** The current shared secret for a source, or null. */
    public static String secretFor(String sourceName) {
        if (secretOverrides != null) {
            return secretOverrides.get(sourceName.toLowerCase());
        }
        Webhook_Secret__c record = Webhook_Secret__c.getInstance(sourceName);
        return record == null ? null : record.Secret__c;
    }

    /**
     * The secrets a delivery may be signed with: the current one, then the previous one while a rotation is in
     * progress. Rotate by moving the old value to Previous Secret and entering the new one; clear Previous Secret
     * once the sender has switched (the "On Previous Secret" list view shows who has not).
     */
    public static List<String> secretsFor(String sourceName) {
        List<String> secrets = new List<String>();
        String current = secretFor(sourceName);
        if (String.isNotBlank(current)) {
            secrets.add(current);
        }
        String previous;
        if (previousSecretOverrides != null) {
            previous = previousSecretOverrides.get(sourceName.toLowerCase());
        } else if (secretOverrides == null) {
            Webhook_Secret__c record = Webhook_Secret__c.getInstance(sourceName);
            previous = record == null ? null : record.Previous_Secret__c;
        }
        if (String.isNotBlank(previous)) {
            secrets.add(previous);
        }
        return secrets;
    }

    /** Retention for a source, active or not; the default for a source that is not configured. */
    public static Integer retentionDaysFor(String sourceName) {
        Source source = String.isBlank(sourceName) ? null : sources().get(sourceName.toLowerCase());
        return source == null ? DEFAULT_RETENTION_DAYS : source.retentionDays;
    }

    /** The shortest retention any source uses, the default included: the purge batch's query horizon. */
    public static Integer shortestRetentionDays() {
        Integer shortest = DEFAULT_RETENTION_DAYS;
        for (Source source : sources().values()) {
            shortest = Math.min(shortest, source.retentionDays);
        }
        return shortest;
    }

    private static Map<String, Source> sources() {
        if (sourceOverrides != null) {
            return sourceOverrides;
        }
        if (cache == null) {
            cache = new Map<String, Source>();
            for (Webhook_Source__mdt record : [
                SELECT DeveloperName, Signature_Header__c, Signature_Prefix__c, Scheme__c, Timestamp_Header__c, Tolerance_Seconds__c,
                    Event_Id_Header__c, Event_Id_Path__c, Event_Type_Header__c, Event_Type_Path__c, Active__c, Retention_Days__c
                FROM Webhook_Source__mdt
                LIMIT 1000
            ]) {
                cache.put(record.DeveloperName.toLowerCase(), new Source(record));
            }
        }
        return cache;
    }
}
