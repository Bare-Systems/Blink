# frozen_string_literal: true

class FixtureSuite < Blink::Testing::Suite
  suite_name "Fixture"

  test "noop", tags: [:smoke], desc: "Confirms fixture suite wiring." do
    assert true
  end
end
