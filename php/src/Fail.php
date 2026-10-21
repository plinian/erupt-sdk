<?php

namespace Erupt;

/**
 * A business error shown to the user as an R message (HTTP 200, success false). Throw it from a
 * DataProxy hook, an operation or a repository; any other exception answers 500.
 */
class Fail extends \RuntimeException
{
}
