namespace Offload.Checks;

static partial class All
{
    public static void Run()
    {
        var only = Environment.GetEnvironmentVariable("OFFLOAD_CHECKS_ONLY");
        bool Want(string name) => string.IsNullOrEmpty(only) || only.Split(',').Contains(name);
        if (Want("safe")) ChecksSafe();
    }
}
