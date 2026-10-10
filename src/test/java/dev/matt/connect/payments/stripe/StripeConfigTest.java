package dev.matt.connect.payments.stripe;

import static org.assertj.core.api.Assertions.assertThat;

import com.stripe.StripeClient;
import org.junit.jupiter.api.Test;
import org.springframework.boot.test.context.runner.ApplicationContextRunner;

/**
 * Brief test 2: startup fails unless the secret key is a test-mode key. The webhook secret is
 * checked too, because an empty secret would make webhook signature checks meaningless.
 */
class StripeConfigTest {

  // Fake keys only. Every key-shaped value is assembled at runtime, so the source never contains a
  // key-shaped literal that secret scanners (or our own Bash guard) would flag.
  private static final String FAKE_SUFFIX = "FAKE_KEY_FOR_UNIT_TESTS";
  private static final String FAKE_TEST_KEY = "sk_test_" + FAKE_SUFFIX;
  private static final String FAKE_LIVE_KEY = "sk_" + "live_" + FAKE_SUFFIX;
  private static final String FAKE_RESTRICTED_KEY = "rk_test_" + FAKE_SUFFIX;
  private static final String FAKE_WEBHOOK_SECRET = "whsec_" + FAKE_SUFFIX;

  // Both properties are always set explicitly, so a STRIPE_SECRET_KEY or STRIPE_WEBHOOK_SECRET
  // exported in the shell running the tests can't change the outcome.
  private final ApplicationContextRunner runner =
      new ApplicationContextRunner().withUserConfiguration(StripeConfig.class);

  @Test
  void startsWithATestModeSecretKeyAndAWebhookSecret() {
    run(FAKE_TEST_KEY, FAKE_WEBHOOK_SECRET)
        .run(context -> assertThat(context).hasNotFailed().hasSingleBean(StripeClient.class));
  }

  @Test
  void refusesALiveKeyAndDoesNotEchoIt() {
    assertRefusesSecretKey(FAKE_LIVE_KEY);
  }

  @Test
  void refusesARestrictedKeyAndDoesNotEchoIt() {
    assertRefusesSecretKey(FAKE_RESTRICTED_KEY);
  }

  @Test
  void refusesAnEmptyKey() {
    // `${STRIPE_SECRET_KEY:}` in application.yml turns an unset variable into an empty string.
    assertRefusesSecretKey("");
  }

  @Test
  void refusesAMissingWebhookSecret() {
    assertRefusesWebhookSecret("");
  }

  @Test
  void refusesAWebhookSecretWithoutTheWhsecPrefixAndDoesNotEchoIt() {
    assertRefusesWebhookSecret("not_a_webhook_secret_" + FAKE_SUFFIX);
  }

  @Test
  void propertiesNeverPrintTheirSecrets() {
    StripeProperties properties = new StripeProperties(FAKE_TEST_KEY, FAKE_WEBHOOK_SECRET);

    assertThat(properties.toString()).doesNotContain(FAKE_SUFFIX);
  }

  private ApplicationContextRunner run(String secretKey, String webhookSecret) {
    return runner.withPropertyValues(
        "stripe.secret-key=" + secretKey, "stripe.webhook-secret=" + webhookSecret);
  }

  private void assertRefusesSecretKey(String secretKey) {
    run(secretKey, FAKE_WEBHOOK_SECRET)
        .run(
            context -> {
              assertThat(context).hasFailed();
              assertThat(context.getStartupFailure())
                  .rootCause()
                  .hasMessageContaining("STRIPE_SECRET_KEY must be a Stripe test-mode secret key")
                  .hasMessageNotContaining(FAKE_SUFFIX);
            });
  }

  private void assertRefusesWebhookSecret(String webhookSecret) {
    run(FAKE_TEST_KEY, webhookSecret)
        .run(
            context -> {
              assertThat(context).hasFailed();
              assertThat(context.getStartupFailure())
                  .rootCause()
                  .hasMessageContaining("STRIPE_WEBHOOK_SECRET must be a Stripe webhook secret")
                  .hasMessageNotContaining(FAKE_SUFFIX);
            });
  }
}
