package dev.matt.connect.payments.stripe;

import com.stripe.StripeClient;
import org.springframework.boot.context.properties.EnableConfigurationProperties;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;

@Configuration
@EnableConfigurationProperties(StripeProperties.class)
public class StripeConfig {

  private static final String TEST_MODE_PREFIX = "sk_test_";
  private static final String WEBHOOK_SECRET_PREFIX = "whsec_";

  /**
   * Network retries let stripe-java retry transient failures; it reuses the same idempotency key on
   * each retry, so a retried write can't be applied twice.
   */
  private static final int MAX_NETWORK_RETRIES = 2;

  /** Both secrets are checked as soon as the configuration loads, so a bad setup never starts. */
  StripeConfig(StripeProperties properties) {
    requireTestModeKey(properties.secretKey());
    requireWebhookSecret(properties.webhookSecret());
  }

  @Bean
  StripeClient stripeClient(StripeProperties properties) {
    return StripeClient.builder()
        .setApiKey(properties.secretKey())
        .setMaxNetworkRetries(MAX_NETWORK_RETRIES)
        .build();
  }

  /**
   * This prototype must never touch live mode. The message deliberately leaves out the key's value,
   * so a wrong key can't end up in logs or test output.
   */
  static void requireTestModeKey(String secretKey) {
    if (secretKey == null || !secretKey.startsWith(TEST_MODE_PREFIX)) {
      throw new IllegalStateException(
          "STRIPE_SECRET_KEY must be a Stripe test-mode secret key starting with "
              + TEST_MODE_PREFIX
              + ". Refusing to start.");
    }
  }

  /**
   * An empty webhook secret would make signature verification meaningless: anyone can compute an
   * HMAC with an empty key. The value is never included in the message.
   */
  static void requireWebhookSecret(String webhookSecret) {
    if (webhookSecret == null || !webhookSecret.startsWith(WEBHOOK_SECRET_PREFIX)) {
      throw new IllegalStateException(
          "STRIPE_WEBHOOK_SECRET must be a Stripe webhook secret starting with "
              + WEBHOOK_SECRET_PREFIX
              + ". Refusing to start.");
    }
  }
}
