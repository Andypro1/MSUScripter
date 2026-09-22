using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Text;
using System.Text.Json.Nodes;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Logging;
using MSURandomizerLibrary.Configs;
using MSURandomizerLibrary.Models;
using MSURandomizerLibrary.Services;
using MSUScripter.Models;

namespace MSUScripter.Services;

public class ApplicationInitializationService(ILogger<ApplicationInitializationService> logger)
{
    public void Initialize()
    {
        logger.LogInformation("Assembly Location: {Location}", Assembly.GetExecutingAssembly().Location);
        logger.LogInformation("Starting MSU Scripter {Version}", App.Version);
        
        var msuInitializationRequest = new MsuRandomizerInitializationRequest
        {
            MsuAppSettingsStream = Assembly.GetExecutingAssembly().GetManifestResourceStream("MSUScripter.Assets.msu-randomizer-settings.yaml"),
            MsuTypeConfigStream = GetMsuTypeConfigStream(),
            UserOptionsPath = Path.Combine(Directories.BaseFolder, "msu-user-settings.yml")
        };

#if DEBUG
        msuInitializationRequest.UserOptionsPath = Path.Combine(Directories.BaseFolder, "msu-user-settings-debug.yml");
#endif
        
        Program.MainHost.Services.GetRequiredService<IMsuRandomizerInitializationService>().Initialize(msuInitializationRequest);

    }

    private static Stream GetMsuTypeConfigStream()
    {
        using var defaultStream = typeof(MsuType).Assembly.GetManifestResourceStream("MSURandomizerLibrary.msu_types.json")
                                  ?? throw new InvalidOperationException("Missing default MSU types");
        using var quadRandoStream = Assembly.GetExecutingAssembly().GetManifestResourceStream("MSUScripter.Assets.quad-rando-msu-type.json")
                                    ?? throw new InvalidOperationException("Missing Quad rando MSU type");
        var msuTypes = JsonNode.Parse(defaultStream)!.AsArray();
        msuTypes.Add(JsonNode.Parse(quadRandoStream));
        return new MemoryStream(Encoding.UTF8.GetBytes(msuTypes.ToJsonString()));
    }
}
